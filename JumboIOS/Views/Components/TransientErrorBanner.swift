import SwiftUI

// MARK: - Transient Error Banner
//
// Lightweight non-blocking error toast for chat actions (vote, reply,
// post). Driven by an optional `String?` on the consuming view model
// — when the VM sets `transientError = "Vote failed. Try again."`,
// the banner slides in from the top, auto-clears after ~2s.
//
// Replaces the old blocking `.alert` for these paths so the user gets
// fast feedback they can dismiss by ignoring rather than tapping.

struct TransientErrorBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
            Text(message)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(Color.red.opacity(0.95))
                .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
        )
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}

extension View {
    /// Attach a top-anchored auto-fading error banner to any view.
    /// Pass the VM's `transientError` published value; the banner
    /// appears whenever it's non-nil and disappears when the VM
    /// clears it (the VM's `showTransientError(_:)` schedules the
    /// auto-clear after ~2s).
    func transientErrorBanner(_ message: String?) -> some View {
        self.overlay(alignment: .top) {
            if let message = message {
                TransientErrorBanner(message: message)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: message)
    }
}
