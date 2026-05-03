import SwiftUI

struct ReportSheet: View {
    let post: Post
    let onSubmit: (ReportReason, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedReason: ReportReason?
    @State private var additionalInfo = ""
    @State private var isSubmitting = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Post preview
                postPreview
                    .padding(16)

                Divider()

                // Report reasons
                ScrollView {
                    VStack(spacing: 12) {
                        Text("Why are you reporting this post?")
                            .font(.system(size: 15, weight: .medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.top, 16)

                        VStack(spacing: 8) {
                            ForEach(ReportReason.allCases, id: \.self) { reason in
                                ReportReasonRow(
                                    reason: reason,
                                    isSelected: selectedReason == reason,
                                    onSelect: { selectedReason = reason }
                                )
                            }
                        }
                        .padding(.horizontal, 16)

                        // Additional info
                        if selectedReason != nil {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Additional details (optional)")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.secondary)

                                TextField("Tell us more...", text: $additionalInfo, axis: .vertical)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 15))
                                    .lineLimit(3...6)
                                    .padding(12)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(Color(.secondarySystemBackground))
                                    )
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                        }

                        // Warning text
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .font(.system(size: 14))

                            Text("False reports may result in action against your account. Please only report genuine violations.")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                        .padding(12)
                        .background(Color(.tertiarySystemBackground))
                        .cornerRadius(12)
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                    }
                    .padding(.bottom, 100)
                }
                .scrollIndicators(.hidden)

                // Submit button
                VStack {
                    Button {
                        submit()
                    } label: {
                        HStack {
                            if isSubmitting {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Image(systemName: "flag.fill")
                                Text("Submit Report")
                            }
                        }
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(selectedReason != nil ? Color.red : Color.gray)
                        )
                    }
                    .disabled(selectedReason == nil || isSubmitting)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .background(Color(.systemBackground))
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Report Post")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var postPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 32, height: 32)
                    .overlay(
                        Text(post.anonymousName.prefix(1))
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.gray)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(post.anonymousName)
                        .font(.system(size: 13, weight: .medium))
                    Text(timeAgo(from: post.createdAt))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            Text(post.content)
                .font(.system(size: 14))
                .lineLimit(3)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    private func timeAgo(from date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400))d ago"
    }

    private func submit() {
        guard let reason = selectedReason else { return }

        isSubmitting = true
        let info = additionalInfo.isEmpty ? nil : additionalInfo

        onSubmit(reason, info)
        dismiss()
    }
}

struct ReportReasonRow: View {
    let reason: ReportReason
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(reason.rawValue)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.primary)

                    Text(reasonDescription)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundColor(isSelected ? .accentColor : .secondary)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? Color.accentColor.opacity(0.1) : Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    private var reasonDescription: String {
        switch reason {
        case .spam:
            return "Repetitive content, ads, or promotional material"
        case .harassment:
            return "Targeting or attacking specific individuals"
        case .hateSpeech:
            return "Discriminatory or hateful language"
        case .misinformation:
            return "False or misleading information"
        case .inappropriate:
            return "Adult content or other inappropriate material"
        case .other:
            return "Other violation not listed above"
        }
    }
}

// MARK: - Block Confirmation Sheet
struct BlockConfirmationSheet: View {
    let anonymousName: String
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 24) {
            // Icon
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.1))
                    .frame(width: 80, height: 80)

                Image(systemName: "person.fill.xmark")
                    .font(.system(size: 32))
                    .foregroundColor(.red)
            }

            // Text
            VStack(spacing: 8) {
                Text("Block \(anonymousName)?")
                    .font(.system(size: 20, weight: .bold))

                Text("You won't see posts or replies from this user. They won't be notified that you blocked them.")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            // Buttons
            VStack(spacing: 12) {
                Button {
                    onConfirm()
                    dismiss()
                } label: {
                    Text("Block User")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.red)
                        )
                }

                Button {
                    dismiss()
                } label: {
                    Text("Cancel")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(.secondarySystemBackground))
                        )
                }
            }
            .padding(.horizontal, 24)
        }
        .padding(.vertical, 32)
        .presentationDetents([.height(380)])
        .presentationDragIndicator(.visible)
    }
}

#Preview("Report Sheet") {
    ReportSheet(
        post: Post.preview(
            authorId: UUID(),
            content: "This is a post that violates community guidelines...",
            upvotes: 5,
            downvotes: 10
        )
    ) { reason, info in
        print("Report: \(reason), \(info ?? "no additional info")")
    }
}

#Preview("Block Confirmation") {
    BlockConfirmationSheet(
        anonymousName: "Blue Tiger",
        onConfirm: { print("Blocked") }
    )
}
