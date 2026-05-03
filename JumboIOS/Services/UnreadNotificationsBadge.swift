import Foundation
import Combine
import OSLog

private let logger = Logger(subsystem: "com.jumbo", category: "notifications")

// MARK: - UnreadNotificationsBadge
//
// Single source of truth for the unread-notifications count surfaced
// on the Alerts tab. Tiny ObservableObject singleton so the count
// can be observed from both `MainTabView` (where the `.badge(...)`
// modifier reads it) and `NotificationsViewModel` (which calls
// `markCleared()` after a successful mark-all-as-read).
//
// Failure handling for `refresh()`:
//   On error we KEEP the existing count rather than zero it. Reasoning:
//   if the user actually has unread notifications and the network
//   refresh fails, dropping the badge to 0 would actively mislead
//   them ("nothing to check") and they might miss real activity.
//   Keeping the stale-but-truthy count is the safer error mode —
//   the badge stays visible, the user can still tap the tab, and
//   the next successful refresh / markCleared corrects it.

@MainActor
final class UnreadNotificationsBadge: ObservableObject {
    static let shared = UnreadNotificationsBadge()

    @Published private(set) var count: Int = 0

    /// Subscription to AppNotificationService.arrivalsPublisher so
    /// the badge increments instantly the moment a new notification
    /// row is INSERTed — even when the user is on a different tab.
    /// Started lazily on first `refresh()` so we don't open the
    /// realtime channel before the app has done anything.
    private var arrivalsCancellable: AnyCancellable?
    private var realtimeStarted: Bool = false

    // MARK: - Background reconciliation
    //
    // The optimistic +1 bump per arrival is fast but assumes every
    // event is delivered exactly once. Realtime can in principle
    // double-deliver (reconnect after a brief drop) or miss an event
    // (channel down longer than the SDK retry window). To keep the
    // local count converging on the server's truth without losing
    // the instant-feedback feel, we periodically replace `count`
    // with `fetchUnreadCount`'s value:
    //
    //   • After every `arrivalsBeforeReconcile` arrivals (immediate
    //     fire) — catches drift in heavy bursts before it gets large.
    //   • Otherwise on a `debounceSeconds` debounce after the last
    //     arrival — avoids hammering the server during a slow drip.
    //
    // Only one reconciliation task is in flight at a time; new
    // arrivals cancel and reschedule. Failures leave `count`
    // unchanged (NEVER zeroed — keeps a stale-but-truthy badge
    // visible during transient outages) and reset the arrivals
    // counter so we don't enter an immediate-retry storm if the
    // RPC is permanently broken.

    private static let arrivalsBeforeReconcile: Int = 5
    private static let debounceNanoseconds: UInt64 = 5_000_000_000   // 5 s

    private var unreconciledArrivals: Int = 0
    private var reconciliationTask: Task<Void, Never>?

    private init() {}

    private var currentUserId: UUID {
        UserPreferences.shared.userId
    }

    /// Fetch the current unread count from Supabase and publish it.
    /// Also lazily starts the realtime arrivals subscription on the
    /// first call so the badge can self-update from any tab without
    /// requiring further explicit triggers.
    ///
    /// On error, the existing `count` is preserved (NOT zeroed) so a
    /// transient network failure can't hide a real unread badge.
    func refresh() async {
        // Lazy-start realtime on first refresh — couples subscription
        // lifetime to "user is using the app", not to "Alerts screen
        // is on screen", so badge updates on Live/Teams/Parties too.
        await ensureRealtimeStarted()

        do {
            let value = try await AppNotificationService.shared.fetchUnreadCount(
                userId: currentUserId
            )
            count = value
            logger.debug("✅ UnreadNotificationsBadge.refresh: count=\(value)")
        } catch {
            // Preserve previous count — see file header for rationale.
            logger.error("⚠️ UnreadNotificationsBadge.refresh failed (non-fatal — keeping count=\(self.count)): \(error)")
        }
    }

    /// Optimistic single-row decrement used by `NotificationsViewModel`
    /// when the user taps an unread notification. Clamped at 0 so
    /// drift can't push the badge negative. Reconciliation will
    /// correct any over-decrement on the next debounce window.
    func decrement() {
        guard count > 0 else { return }
        count -= 1
        logger.debug("✅ UnreadNotificationsBadge.decrement: count=\(self.count)")
    }

    /// Optimistic clear used by `NotificationsViewModel` immediately
    /// after a successful `markAllAsRead`. Drops the badge instantly
    /// instead of waiting for the next refresh round-trip to confirm.
    /// Safe to call multiple times.
    ///
    /// Also cancels any pending reconciliation — without that, a
    /// reconciliation that started before the markAllAsRead could
    /// fire seconds later and re-set `count` to a now-stale value
    /// (the snapshot it captured, not the post-mark zero).
    func markCleared() {
        // Always cancel pending reconciliation, even if count is
        // already 0 (defensive — e.g., user opens Alerts twice in
        // quick succession).
        reconciliationTask?.cancel()
        reconciliationTask = nil
        unreconciledArrivals = 0

        guard count != 0 else { return }
        logger.debug("✅ UnreadNotificationsBadge.markCleared: dropping badge (was \(self.count))")
        count = 0
    }

    // MARK: - Realtime wiring

    private func ensureRealtimeStarted() async {
        guard !realtimeStarted else { return }
        realtimeStarted = true

        // Subscribe to arrivals BEFORE starting the channel so any
        // event that fires immediately on connection is captured.
        arrivalsCancellable = AppNotificationService.shared.arrivalsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.bumpForArrival()
            }

        await AppNotificationService.shared.startRealtimeSubscription(for: currentUserId)
        logger.debug("✅ UnreadNotificationsBadge: arrivals subscription armed for \(self.currentUserId.uuidString)")
    }

    /// Increment the badge by 1 for a single arrival. The realtime
    /// filter is server-side `user_id=eq.<currentUser>`, so every
    /// arrival is genuinely for this user — safe to bump without
    /// re-querying.
    ///
    /// Also schedules a background reconciliation so the local count
    /// converges on the server's truth even if a realtime event was
    /// missed or duplicated. Two trigger conditions, whichever
    /// expires first; only one task is in flight at a time:
    ///   • Burst: ≥ `arrivalsBeforeReconcile` arrivals → fire now
    ///     (delay = 0). Catches drift fast under heavy load.
    ///   • Trickle: less than the threshold → debounce
    ///     `debounceNanoseconds` after the most recent arrival.
    ///     Avoids hammering the server during a slow drip.
    private func bumpForArrival() {
        count += 1
        unreconciledArrivals += 1
        logger.debug("📨 UnreadNotificationsBadge.bumpForArrival: count=\(self.count) unreconciled=\(self.unreconciledArrivals)")

        scheduleReconciliation()
    }

    private func scheduleReconciliation() {
        let delay: UInt64 = unreconciledArrivals >= Self.arrivalsBeforeReconcile
            ? 0
            : Self.debounceNanoseconds

        // Cancel any prior pending reconciliation so multiple
        // arrivals coalesce into a single server fetch.
        reconciliationTask?.cancel()
        reconciliationTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard !Task.isCancelled else { return }
            await self?.reconcile()
        }
    }

    /// Replace `count` with the server's authoritative unread count.
    /// Detached from the bump path — the +1 already gave the user
    /// instant feedback; this is the eventual-consistency pass.
    /// On failure, `count` is preserved (NEVER zeroed) and the
    /// arrivals counter resets to avoid a retry storm if the RPC
    /// is permanently broken — the next normal arrival re-arms the
    /// debounce path and we try again.
    private func reconcile() async {
        do {
            let serverCount = try await AppNotificationService.shared.fetchUnreadCount(
                userId: currentUserId
            )
            let priorLocal = count
            count = serverCount
            unreconciledArrivals = 0
            logger.debug("✅ UnreadNotificationsBadge.reconcile: replaced local=\(priorLocal) with server=\(serverCount)")
        } catch {
            logger.error("⚠️ UnreadNotificationsBadge.reconcile failed (non-fatal — keeping count=\(self.count)): \(error)")
            // Reset arrivals so the next bump goes through the normal
            // debounce path, not into immediate-retry storm. Local
            // count stays — bumps from server-filtered events are
            // already correct as long as nothing was missed/duped.
            unreconciledArrivals = 0
        }
    }
}
