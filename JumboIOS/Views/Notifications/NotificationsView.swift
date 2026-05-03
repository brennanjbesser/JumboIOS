import SwiftUI
import Combine
import OSLog

private let logger = Logger(subsystem: "com.jumbo", category: "notifications")

// MARK: - NotificationsView
//
// In-app notifications screen. Shows the current user's notifications
// (replies, upvotes for now) newest first.
//
// Behavior:
//   • On appear: fetch list, mark all as read.
//   • Each row shows source user's username + avatar (resolved from
//     public.users in one batch fetch) and is tappable to open
//     UserProfileSheet for that user.
//   • Realtime: while the screen is alive, the VM observes
//     AppNotificationService.arrivalsPublisher (a long-lived
//     server-filtered INSERT subscription) and prepends new rows
//     to the top live — no need to leave/return.
//   • Badge: the shared UnreadNotificationsBadge owns the realtime
//     channel via the same arrivals stream, so tab badge updates
//     instantly from any tab. NotificationsViewModel does not poke
//     the badge on its own beyond the markCleared() call after
//     markAllAsRead succeeds.
//
// Identity:
//   The current user id is `UserPreferences.shared.userId`. This is
//   the same value `RemoteChatService.ensureCurrentUserExists`
//   upserts into `public.users.id`, so the
//   `notifications.user_id REFERENCES public.users(id)` FK is
//   satisfied for both reads and writes.

struct NotificationsView: View {
    @StateObject private var viewModel = NotificationsViewModel()
    @State private var profileTarget: ProfileSheetTarget?
    /// Set when a notification row is tapped → drives the
    /// .navigationDestination push to CasinoThreadView. The VM's
    /// `prepareThreadTarget(for:)` does the post fetch + parent
    /// resolution and assigns the result here.
    @State private var threadTarget: Post?

    /// Foreground-resume hook so notifications + their source
    /// profiles refresh when the app comes back from background.
    /// Without this, a user who edited their username while the
    /// recipient device was backgrounded wouldn't show up with
    /// the new name until the recipient navigated away/back.
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            ZStack {
                FanChatTheme.backgroundPrimary
                    .ignoresSafeArea()

                content
            }
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FanChatTheme.backgroundPrimary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .navigationDestination(item: $threadTarget) { post in
                // Same destination the room VMs push for their own
                // post taps (GameRoom/TeamPage/Trending/Feed/Money).
                CasinoThreadView(parentPost: post)
            }
        }
        .task {
            // Fetch first so the unread visual difference is visible
            // for at least one render pass; THEN mark as read in the
            // background. markAllAsRead success kicks off a silent
            // refetch that flips the rows' read styling without
            // showing a spinner or losing the user's position.
            await viewModel.loadNotifications()
            await viewModel.markAllAsRead()
        }
        .onChange(of: scenePhase) { _, newPhase in
            // On foreground resume, re-fetch so the list AND every
            // visible source-user profile reflects any edits that
            // happened while the app was backgrounded. The fetch
            // path's profile cache no longer skips already-cached
            // ids, so this picks up changed usernames/avatars.
            if newPhase == .active {
                Task { await viewModel.loadNotifications() }
            }
        }
        .sheet(item: $profileTarget) { target in
            // Reuses the existing app-wide profile sheet — same one
            // shown from CasinoPostCard / CasinoReplyCard avatar taps.
            UserProfileSheet(authorId: target.id)
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.notifications.isEmpty {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(FanChatTheme.neonOrange)
        } else if let errorMessage = viewModel.errorMessage, viewModel.notifications.isEmpty {
            errorState(message: errorMessage)
        } else if viewModel.notifications.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(viewModel.notifications) { notification in
                        NotificationRow(
                            notification: notification,
                            sourceProfile: notification.sourceUserId.flatMap { viewModel.userProfiles[$0] },
                            onProfileTap: { userId in
                                profileTarget = ProfileSheetTarget(id: userId)
                            },
                            onRowTap: {
                                Task {
                                    // Mark this single row as read,
                                    // resolve the thread target, then
                                    // push. VM handles post-fetch +
                                    // parent walk for upvote-on-reply
                                    // and silent-failure logging.
                                    await viewModel.handleRowTap(notification)
                                    if let target = await viewModel.resolveThreadTarget(for: notification) {
                                        threadTarget = target
                                    }
                                }
                            }
                        )
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.vertical, 12)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "bell.slash.fill")
                .font(.system(size: 44))
                .foregroundColor(FanChatTheme.textTertiary)
            Text("No notifications yet")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(FanChatTheme.textSecondary)
            Text("Replies and upvotes on your posts will show up here.")
                .font(.system(size: 14))
                .foregroundColor(FanChatTheme.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    private func errorState(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundColor(FanChatTheme.neonOrange)
            Text("Couldn't load notifications")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(FanChatTheme.textSecondary)
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(FanChatTheme.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                Task { await viewModel.loadNotifications() }
            } label: {
                Text("Retry")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(FanChatTheme.neonOrange))
                    .foregroundColor(.black)
            }
        }
    }
}

/// Wrapper so `UUID` can drive `.sheet(item:)` (UUID isn't
/// Identifiable). Used to surface the source-user UserProfileSheet
/// when the user taps a notification row's username/avatar.
private struct ProfileSheetTarget: Identifiable {
    let id: UUID
}

// MARK: - Row

private struct NotificationRow: View {
    let notification: AppNotification
    let sourceProfile: AppUserProfile?
    let onProfileTap: (UUID) -> Void
    /// Tap on the row body (anywhere except the avatar/username
    /// nested buttons). Drives mark-as-read + navigate-to-thread.
    let onRowTap: () -> Void

    var body: some View {
        // Whole-row tappable surface. The nested Buttons (avatar,
        // username) take precedence inside their bounds because
        // SwiftUI dispatches the inner-most hit first; tapping the
        // body or the preview line falls through to onRowTap.
        Button {
            onRowTap()
        } label: {
            rowContent
        }
        .buttonStyle(.plain)
    }

    private var rowContent: some View {
        HStack(alignment: .top, spacing: 12) {
            // Tappable source-user avatar. Falls back to the
            // deterministic UUID-byte avatar when the profile
            // lookup hasn't returned (or returned blank fields)
            // so the visual stays consistent across devices.
            if let sourceUserId = notification.sourceUserId {
                Button {
                    onProfileTap(sourceUserId)
                } label: {
                    avatarView(for: sourceUserId)
                }
                .buttonStyle(.plain)
            } else {
                // No source user (e.g., source row was deleted with
                // ON DELETE SET NULL). Render a neutral placeholder
                // and skip the tap target.
                placeholderAvatar
            }

            // Username + action text, optional preview snippet, time.
            VStack(alignment: .leading, spacing: 4) {
                actionLine

                // Preview snippet — quoted, italic, 2 lines max.
                // Only renders when the notification has stored a
                // preview (post-migration rows). Older rows simply
                // don't show this line.
                if let preview = previewSnippet, !preview.isEmpty {
                    Text("\u{201C}\(preview)\u{201D}")   // “preview”
                        .font(.system(size: 13))
                        .italic()
                        .foregroundColor(FanChatTheme.textSecondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }

                Text(timeAgo(from: notification.createdAt))
                    .font(.system(size: 12))
                    .foregroundColor(FanChatTheme.textTertiary)
            }

            Spacer(minLength: 0)

            // Type icon as a trailing indicator (vs the leading
            // avatar which is the actor's identity).
            VStack(spacing: 6) {
                Image(systemName: typeIconName)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(typeColor)
                if !notification.read {
                    Circle()
                        .fill(FanChatTheme.neonOrange)
                        .frame(width: 8, height: 8)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(notification.read
                      ? FanChatTheme.backgroundSecondary
                      : FanChatTheme.backgroundSecondary.opacity(0.6))
        )
        .overlay(
            // Subtle left accent bar for unread rows.
            HStack(spacing: 0) {
                Rectangle()
                    .fill(notification.read ? Color.clear : FanChatTheme.neonOrange)
                    .frame(width: 3)
                    .clipShape(RoundedRectangle(cornerRadius: 1.5))
                Spacer()
            }
        )
        .contentShape(Rectangle())   // make whole frame tappable
    }

    /// Trim whitespace and collapse newlines so the preview reads
    /// cleanly on a single quoted line. Returns nil when no preview
    /// is stored (older notifications pre-migration).
    private var previewSnippet: String? {
        guard let raw = notification.previewText else { return nil }
        let trimmed = raw
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Identity rendering

    /// Resolved username for display in the row sentence. Prefers
    /// the server-fetched profile; falls back to the literal
    /// "Someone" when missing (e.g., source user row not in the
    /// users batch fetch, or `sourceUserId` itself is nil because
    /// the source row was deleted via ON DELETE SET NULL).
    ///
    /// Note: avatar identity in the same row still uses
    /// `Post.deterministicAvatar*` so the visual stays consistent
    /// across devices — only the displayed username falls back to
    /// the human-readable "Someone".
    private func displayName(for sourceUserId: UUID?) -> String {
        if let resolved = sourceProfile?.username, !resolved.isEmpty {
            return resolved
        }
        return "Someone"
    }

    /// Resolved avatar emoji. Same precedence: profile → deterministic.
    private func avatarEmoji(for sourceUserId: UUID) -> String {
        if let emoji = sourceProfile?.avatarEmoji, !emoji.isEmpty {
            return emoji
        }
        return Post.deterministicAvatarEmoji(for: sourceUserId)
    }

    /// Resolved avatar color. Same precedence: profile → deterministic.
    private func avatarColor(for sourceUserId: UUID) -> Color {
        if let hex = sourceProfile?.avatarColor, !hex.isEmpty {
            return Color(hex: hex)
        }
        return Color(hex: Post.deterministicAvatarColorHex(for: sourceUserId))
    }

    private func avatarView(for sourceUserId: UUID) -> some View {
        ZStack {
            Circle()
                .fill(avatarColor(for: sourceUserId))
                .frame(width: 36, height: 36)
            Text(avatarEmoji(for: sourceUserId))
                .font(.system(size: 18))
        }
    }

    private var placeholderAvatar: some View {
        ZStack {
            Circle()
                .fill(Color.gray.opacity(0.4))
                .frame(width: 36, height: 36)
            Image(systemName: "person.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
        }
    }

    /// "[username] [action verb]" as an HStack of two distinct
    /// tap targets:
    ///   • The username is its own `Button` → `onProfileTap`
    ///     (opens UserProfileSheet via the parent's sheet binding).
    ///   • The verb is a plain `Text` with no Button wrapper, so
    ///     taps on it bubble up to the outer row Button →
    ///     `onRowTap` (mark-as-read + navigate to thread).
    ///
    /// When the source user is nil (deleted via ON DELETE SET NULL),
    /// there's no profile to open — fall back to a single
    /// `Text + Text` line so it still reads as one sentence (and
    /// any tap falls through to the outer row Button as expected).
    @ViewBuilder
    private var actionLine: some View {
        if let sourceUserId = notification.sourceUserId {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Button {
                    onProfileTap(sourceUserId)
                } label: {
                    Text(displayName(for: sourceUserId))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(FanChatTheme.neonBlue)
                }
                .buttonStyle(.plain)
                // Don't truncate the username under layout pressure
                // — better to wrap the verb to the next line than
                // chop the user's name with an ellipsis.
                .fixedSize(horizontal: true, vertical: false)

                Text(actionVerb)
                    .font(.system(size: 14, weight: notification.read ? .regular : .semibold))
                    .foregroundColor(FanChatTheme.textPrimary)
                    // Allow the verb to wrap to additional lines so
                    // longer usernames don't cause it to truncate.
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            // No source — single line, no per-segment tap target.
            // Falls through to the outer row Button on tap.
            (Text("Someone")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(FanChatTheme.neonBlue)
            + Text(" \(actionVerb)")
                .font(.system(size: 14, weight: notification.read ? .regular : .semibold))
                .foregroundColor(FanChatTheme.textPrimary))
        }
    }

    private var actionVerb: String {
        switch notification.type {
        case .reply:  return "replied to your post"
        case .upvote: return "upvoted your post"
        }
    }

    private var typeIconName: String {
        switch notification.type {
        case .reply:  return "bubble.left.fill"
        case .upvote: return "arrow.up.circle.fill"
        }
    }

    private var typeColor: Color {
        switch notification.type {
        case .reply:  return FanChatTheme.neonBlue
        case .upvote: return FanChatTheme.upvoteColor
        }
    }

    private func timeAgo(from date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60   { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400))d ago"
    }
}

// MARK: - View Model

@MainActor
final class NotificationsViewModel: ObservableObject {
    @Published private(set) var notifications: [AppNotification] = []
    @Published private(set) var userProfiles: [UUID: AppUserProfile] = [:]
    @Published private(set) var isLoading: Bool = false
    @Published var errorMessage: String?

    private var cancellables = Set<AnyCancellable>()

    private var currentUserId: UUID {
        UserPreferences.shared.userId
    }

    init() {
        // Live updates while Alerts is open. The shared service owns
        // the underlying realtime channel (started lazily by
        // UnreadNotificationsBadge.refresh on app launch); we just
        // listen to the rebroadcast subject. cancellables on the VM
        // ensures the observation cleans up when the VM deallocs —
        // the channel itself stays open for the badge.
        //
        // `.receive(on: DispatchQueue.main)` ensures the sink fires
        // on main thread; the `Task { @MainActor in … }` then hops
        // into MainActor isolation so we can write @Published state
        // and call MainActor-isolated methods on `self`.
        AppNotificationService.shared.arrivalsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                logger.debug("🔔 NotificationsViewModel.sink: received arrival id=\(notification.id.uuidString) (on main thread, hopping to actor)")
                Task { @MainActor [weak self] in
                    await self?.handleArrival(notification)
                }
            }
            .store(in: &cancellables)

        // Realtime user-profile updates. RemoteChatService owns
        // the underlying channel (started by MainTabView's
        // `.task` / `scenePhase` hook); we just listen for
        // republished AppUserProfile events and refresh our own
        // per-screen `userProfiles` cache. SwiftUI re-renders any
        // visible row that reads from this dict.
        RemoteChatService.shared.userProfileUpdatesPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] profile in
                self?.handleUserProfileUpdate(profile)
            }
            .store(in: &cancellables)

        logger.debug("🟢 NotificationsViewModel.init: arrivals + user-profile subscriptions active")
    }

    private func handleUserProfileUpdate(_ profile: AppUserProfile) {
        logger.debug("🪪 NotificationsViewModel.handleUserProfileUpdate: user=\(profile.id.uuidString) username='\(profile.username)'")
        userProfiles[profile.id] = profile
    }

    /// Pull the most recent notifications for the current user, then
    /// batch-fetch source-user profiles in one round-trip (no N+1).
    /// Failures populate `errorMessage` and leave the existing
    /// notifications array intact — never crashes.
    func loadNotifications() async {
        isLoading = true
        errorMessage = nil
        do {
            let fetched = try await AppNotificationService.shared.fetchNotifications(
                userId: currentUserId,
                limit: 50
            )
            notifications = fetched
            logger.debug("✅ NotificationsViewModel.loadNotifications: \(fetched.count) row(s)")

            // Batch-resolve source user profiles for the fetched rows.
            // Missing profiles fall back to deterministic identity in
            // the row view, so this best-effort fetch failing is OK.
            await refreshUserProfiles(forSourceIdsIn: fetched)
        } catch {
            errorMessage = error.localizedDescription
            logger.error("❌ NotificationsViewModel.loadNotifications failed: \(error)")
        }
        isLoading = false
    }

    /// Best-effort mark-all-as-read. Silent on failure.
    /// On success: clears badge + queues silent refetch (so rows flip
    /// to the read style without flicker).
    func markAllAsRead() async {
        do {
            try await AppNotificationService.shared.markAllAsRead(userId: currentUserId)
            UnreadNotificationsBadge.shared.markCleared()
            logger.debug("✅ NotificationsViewModel.markAllAsRead: succeeded; badge cleared; queueing silent refetch")
            Task { [weak self] in
                await self?.silentlyRefetch()
            }
        } catch {
            logger.error("⚠️ NotificationsViewModel.markAllAsRead failed (non-fatal — UI unaffected): \(error)")
        }
    }

    /// Realtime arrival handler. Always inserts at index 0 unless
    /// the id is already present (dedupe). Spec: "always inserts
    /// at index 0 if id not present".
    private func handleArrival(_ notification: AppNotification) async {
        logger.debug("📥 NotificationsViewModel.handleArrival: ENTRY id=\(notification.id.uuidString) recipient=\(notification.userId.uuidString) currentUser=\(self.currentUserId.uuidString)")

        // Defensive: only handle arrivals for the current user. The
        // server-side filter already guarantees this, but covers
        // identity changes mid-session (e.g., debug Reset Local User).
        guard notification.userId == currentUserId else {
            logger.debug("    SKIP — recipient mismatch")
            return
        }
        guard !notifications.contains(where: { $0.id == notification.id }) else {
            logger.debug("    SKIP — duplicate (already in list)")
            return
        }

        // INSERT at index 0. This @Published mutation publishes
        // before the await below, so the row appears in the UI
        // immediately — the profile fetch is cosmetic (username text
        // upgrades from "Someone" → real name once it lands).
        notifications.insert(notification, at: 0)
        logger.debug("    ✅ INSERTED at index 0 — list now has \(self.notifications.count) item(s)")

        // Fetch missing source profile — single-id call so it's cheap.
        if let sourceUserId = notification.sourceUserId,
           userProfiles[sourceUserId] == nil {
            await refreshUserProfiles(forSourceIds: [sourceUserId])
            logger.debug("    👤 source profile cache updated for \(sourceUserId.uuidString)")
        }
    }

    private func silentlyRefetch() async {
        do {
            let fresh = try await AppNotificationService.shared.fetchNotifications(
                userId: currentUserId,
                limit: 50
            )

            // Merge instead of replace, to defend against the race
            // where a realtime arrival landed in `notifications`
            // AFTER `fetch` was issued but BEFORE this assignment —
            // a plain `notifications = fresh` would silently drop
            // those arrivals from the visible list.
            //
            // Strategy: take fresh as the base (it's authoritative
            // for read-state of every row server-side), then add any
            // local-only ids that aren't in fresh, then sort newest
            // first.
            let freshIds = Set(fresh.map { $0.id })
            let localOnly = notifications.filter { !freshIds.contains($0.id) }
            let merged = (localOnly + fresh).sorted { $0.createdAt > $1.createdAt }
            notifications = merged

            // Re-fetch profiles in case new rows brought new sources.
            await refreshUserProfiles(forSourceIdsIn: merged)
            logger.debug("✅ NotificationsViewModel.silentlyRefetch: merged fresh=\(fresh.count) + localOnly=\(localOnly.count) = \(merged.count) row(s)")
        } catch {
            logger.error("⚠️ NotificationsViewModel.silentlyRefetch failed (non-fatal — UI unchanged): \(error)")
        }
    }

    /// Convenience: batch-resolve source profiles for an array of
    /// notifications. Always re-fetches (no skip-if-cached) so a
    /// source user's edited username/avatar surfaces on the next
    /// notifications refresh — without this, the first lookup would
    /// freeze the row's identity for the rest of the session.
    private func refreshUserProfiles(forSourceIdsIn rows: [AppNotification]) async {
        let needed = rows.compactMap { $0.sourceUserId }
        await refreshUserProfiles(forSourceIds: needed)
    }

    private func refreshUserProfiles(forSourceIds ids: [UUID]) async {
        guard !ids.isEmpty else { return }
        do {
            let resolved = try await AppNotificationService.shared.fetchUserProfiles(ids: ids)
            for (key, value) in resolved {
                userProfiles[key] = value
            }
            logger.debug("✅ NotificationsViewModel.refreshUserProfiles: cached \(resolved.count) profile(s); total \(self.userProfiles.count)")
        } catch {
            // Non-fatal — rows fall back to deterministic identity
            // when the profile is missing.
            logger.error("⚠️ NotificationsViewModel.refreshUserProfiles failed (non-fatal — rows fall back to deterministic identity): \(error)")
        }
    }

    // MARK: - Row tap

    /// Mark a single notification as read on tap, both server-side
    /// and locally. Optimistic — local row flips to read styling
    /// immediately; server failure is logged silently. Also bumps
    /// the badge down by one for instant feedback (background
    /// reconciliation in UnreadNotificationsBadge will correct any
    /// drift if the markAsRead actually failed).
    func handleRowTap(_ notification: AppNotification) async {
        guard !notification.read else { return }

        // Optimistic local flip — replace the row with a read=true
        // copy. AppNotification is a value type, so we rebuild it
        // (no mutating fields).
        if let idx = notifications.firstIndex(where: { $0.id == notification.id }) {
            let r = notifications[idx]
            notifications[idx] = AppNotification(
                id: r.id,
                userId: r.userId,
                type: r.type,
                sourceUserId: r.sourceUserId,
                postId: r.postId,
                roomId: r.roomId,
                previewText: r.previewText,
                createdAt: r.createdAt,
                read: true
            )
        }

        // Optimistic badge decrement so the user gets instant
        // tab-level feedback for tapping a single unread row.
        UnreadNotificationsBadge.shared.decrement()

        do {
            try await AppNotificationService.shared.markAsRead(
                notificationId: notification.id,
                userId: currentUserId
            )
            logger.debug("✅ NotificationsViewModel.handleRowTap: \(notification.id.uuidString) marked read")
        } catch {
            logger.error("⚠️ NotificationsViewModel.handleRowTap markAsRead failed (non-fatal — local row stays read): \(error)")
        }
    }

    /// Resolve the Post that should be passed to CasinoThreadView
    /// when the user taps this notification. For:
    ///   • reply notifications, `post_id` is the parent — fetch and
    ///     return it directly; the thread VM loads the reply
    ///     itself among the replies list.
    ///   • upvote notifications on a top-level post, `post_id` is
    ///     the post being voted on — return it; thread opens to it.
    ///   • upvote notifications on a reply, `post_id` is the reply;
    ///     walk to its `parentId`, fetch that, return it.
    /// Returns nil if the post(s) can't be loaded (deleted, network
    /// failure) — caller silently skips navigation.
    func resolveThreadTarget(for notification: AppNotification) async -> Post? {
        guard let postId = notification.postId else {
            logger.debug("ℹ️ NotificationsViewModel.resolveThreadTarget: notification \(notification.id.uuidString) has no post_id, skipping")
            return nil
        }
        do {
            guard let primary = try await RemoteChatService.shared.fetchPost(id: postId) else {
                logger.debug("ℹ️ NotificationsViewModel.resolveThreadTarget: post \(postId.uuidString) not found")
                return nil
            }
            // If primary IS a reply, walk to its parent so the
            // pushed thread shows the surrounding context.
            if let parentId = primary.parentId {
                if let parent = try await RemoteChatService.shared.fetchPost(id: parentId) {
                    logger.debug("✅ NotificationsViewModel.resolveThreadTarget: \(postId.uuidString) is a reply → returning parent \(parentId.uuidString)")
                    return parent
                }
                // Parent missing — fall back to the primary so we
                // still navigate somewhere instead of failing.
                logger.error("⚠️ NotificationsViewModel.resolveThreadTarget: reply's parent \(parentId.uuidString) missing — opening reply itself")
                return primary
            }
            logger.debug("✅ NotificationsViewModel.resolveThreadTarget: returning top-level \(postId.uuidString)")
            return primary
        } catch {
            logger.error("❌ NotificationsViewModel.resolveThreadTarget failed for notification \(notification.id.uuidString): \(error)")
            return nil
        }
    }
}
