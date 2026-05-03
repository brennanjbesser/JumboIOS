import SwiftUI

struct CasinoReportSheet: View {
    let post: Post
    let onSubmit: (ReportReason, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedReason: ReportReason?
    @State private var additionalInfo = ""
    @State private var isSubmitting = false

    var body: some View {
        NavigationStack {
            ZStack {
                // Dark background
                FanChatTheme.backgroundPrimary
                    .ignoresSafeArea()

                NoiseBackground()
                    .opacity(0.3)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    // Post preview
                    postPreview
                        .padding(16)

                    // Glowing divider
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [.clear, FanChatTheme.neonRed.opacity(0.3), .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(height: 1)

                    // Report reasons
                    ScrollView {
                        VStack(spacing: 12) {
                            Text("WHY ARE YOU REPORTING?")
                                .font(.system(size: 11, weight: .black))
                                .foregroundColor(FanChatTheme.textTertiary)
                                .tracking(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.top, 16)

                            VStack(spacing: 8) {
                                ForEach(ReportReason.allCases, id: \.self) { reason in
                                    CasinoReportReasonRow(
                                        reason: reason,
                                        isSelected: selectedReason == reason,
                                        onSelect: {
                                            withAnimation(AnimationConfig.snappy) {
                                                selectedReason = reason
                                            }
                                            let generator = UIImpactFeedbackGenerator(style: .light)
                                            generator.impactOccurred()
                                        }
                                    )
                                }
                            }
                            .padding(.horizontal, 16)

                            // Additional info
                            if selectedReason != nil {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("ADDITIONAL DETAILS")
                                        .font(.system(size: 11, weight: .black))
                                        .foregroundColor(FanChatTheme.textTertiary)
                                        .tracking(1)

                                    TextField("Tell us more... (optional)", text: $additionalInfo, axis: .vertical)
                                        .textFieldStyle(.plain)
                                        .font(.system(size: 15))
                                        .foregroundColor(FanChatTheme.textPrimary)
                                        .lineLimit(3...6)
                                        .padding(12)
                                        .background(
                                            RoundedRectangle(cornerRadius: 12)
                                                .fill(FanChatTheme.backgroundSecondary)
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 12)
                                                .stroke(FanChatTheme.backgroundTertiary, lineWidth: 1)
                                        )
                                }
                                .padding(.horizontal, 16)
                                .padding(.top, 8)
                                .transition(.asymmetric(
                                    insertion: .move(edge: .top).combined(with: .opacity),
                                    removal: .opacity
                                ))
                            }

                            // Warning text
                            warningView
                                .padding(.horizontal, 16)
                                .padding(.top, 16)
                        }
                        .padding(.bottom, 120)
                    }
                    .scrollIndicators(.hidden)

                    // Submit button
                    submitButton
                }
            }
            .navigationTitle("Report Post")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FanChatTheme.backgroundPrimary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundColor(FanChatTheme.textSecondary)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(FanChatTheme.backgroundPrimary)
        .preferredColorScheme(.dark)
    }

    private var postPreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ZStack {
                    Circle()
                        .fill(FanChatTheme.backgroundTertiary)
                        .frame(width: 36, height: 36)

                    Text(post.anonymousName.prefix(1))
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(FanChatTheme.textSecondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(post.anonymousName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(FanChatTheme.textPrimary)
                    Text(timeAgo(from: post.createdAt))
                        .font(.system(size: 12))
                        .foregroundColor(FanChatTheme.textTertiary)
                }

                Spacer()

                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(FanChatTheme.neonOrange)
                    .glow(FanChatTheme.neonOrange, radius: 4)
            }

            Text(post.content)
                .font(.system(size: 14))
                .foregroundColor(FanChatTheme.textSecondary)
                .lineLimit(3)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(FanChatTheme.backgroundSecondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(FanChatTheme.neonOrange.opacity(0.3), lineWidth: 1)
        )
    }

    private var warningView: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundColor(FanChatTheme.neonYellow)
                .font(.system(size: 16))
                .glow(FanChatTheme.neonYellow, radius: 4)

            Text("False reports may result in action against your account. Please only report genuine violations.")
                .font(.system(size: 12))
                .foregroundColor(FanChatTheme.textTertiary)
                .lineSpacing(2)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(FanChatTheme.neonYellow.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(FanChatTheme.neonYellow.opacity(0.2), lineWidth: 1)
        )
    }

    private var submitButton: some View {
        VStack {
            Button {
                submit()
            } label: {
                HStack(spacing: 10) {
                    if isSubmitting {
                        CasinoSpinner()
                            .scaleEffect(0.6)
                    } else {
                        Image(systemName: "flag.fill")
                            .font(.system(size: 16, weight: .semibold))
                        Text("Submit Report")
                            .font(.system(size: 16, weight: .bold))
                    }
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(selectedReason != nil ?
                              AnyShapeStyle(LinearGradient(colors: [FanChatTheme.neonRed, FanChatTheme.neonPink], startPoint: .leading, endPoint: .trailing)) :
                              AnyShapeStyle(FanChatTheme.backgroundTertiary))
                )
                .glow(FanChatTheme.neonRed, radius: 8, isActive: selectedReason != nil)
            }
            .disabled(selectedReason == nil || isSubmitting)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(
            FanChatTheme.backgroundSecondary
                .overlay(
                    Rectangle()
                        .fill(FanChatTheme.backgroundTertiary)
                        .frame(height: 0.5),
                    alignment: .top
                )
        )
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

        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)

        isSubmitting = true
        let info = additionalInfo.isEmpty ? nil : additionalInfo

        onSubmit(reason, info)
        dismiss()
    }
}

// MARK: - Casino Report Reason Row
struct CasinoReportReasonRow: View {
    let reason: ReportReason
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 14) {
                // Icon
                ZStack {
                    Circle()
                        .fill(isSelected ? FanChatTheme.neonRed.opacity(0.2) : FanChatTheme.backgroundTertiary)
                        .frame(width: 40, height: 40)

                    Image(systemName: reasonIcon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(isSelected ? FanChatTheme.neonRed : FanChatTheme.textSecondary)
                        .glow(FanChatTheme.neonRed, radius: 4, isActive: isSelected)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(reason.rawValue)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(FanChatTheme.textPrimary)

                    Text(reasonDescription)
                        .font(.system(size: 12))
                        .foregroundColor(FanChatTheme.textTertiary)
                        .lineLimit(2)
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 24))
                    .foregroundColor(isSelected ? FanChatTheme.neonGreen : FanChatTheme.textTertiary)
                    .glow(FanChatTheme.neonGreen, radius: 4, isActive: isSelected)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isSelected ? FanChatTheme.neonRed.opacity(0.08) : FanChatTheme.backgroundSecondary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isSelected ? FanChatTheme.neonRed.opacity(0.3) : FanChatTheme.backgroundTertiary, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var reasonIcon: String {
        switch reason {
        case .spam:
            return "envelope.badge.fill"
        case .harassment:
            return "person.fill.xmark"
        case .hateSpeech:
            return "exclamationmark.bubble.fill"
        case .misinformation:
            return "doc.questionmark.fill"
        case .inappropriate:
            return "eye.slash.fill"
        case .other:
            return "ellipsis.circle.fill"
        }
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

// MARK: - Casino Block Confirmation Sheet
struct CasinoBlockConfirmationSheet: View {
    let anonymousName: String
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            FanChatTheme.backgroundPrimary
                .ignoresSafeArea()

            VStack(spacing: 24) {
                // Icon
                ZStack {
                    Circle()
                        .fill(FanChatTheme.neonRed.opacity(0.15))
                        .frame(width: 90, height: 90)

                    Circle()
                        .fill(FanChatTheme.neonRed.opacity(0.1))
                        .frame(width: 110, height: 110)
                        .blur(radius: 10)

                    Image(systemName: "person.fill.xmark")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundColor(FanChatTheme.neonRed)
                        .glow(FanChatTheme.neonRed, radius: 8)
                }

                // Text
                VStack(spacing: 10) {
                    Text("Block \(anonymousName)?")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(FanChatTheme.textPrimary)

                    Text("You won't see posts or replies from this user. They won't be notified that you blocked them.")
                        .font(.system(size: 14))
                        .foregroundColor(FanChatTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                // Buttons
                VStack(spacing: 12) {
                    Button {
                        let generator = UINotificationFeedbackGenerator()
                        generator.notificationOccurred(.success)
                        onConfirm()
                        dismiss()
                    } label: {
                        Text("Block User")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .background(
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(
                                        LinearGradient(
                                            colors: [FanChatTheme.neonRed, FanChatTheme.neonPink],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                            )
                            .glow(FanChatTheme.neonRed, radius: 8)
                    }

                    Button {
                        dismiss()
                    } label: {
                        Text("Cancel")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(FanChatTheme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .background(
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(FanChatTheme.backgroundSecondary)
                            )
                    }
                }
                .padding(.horizontal, 24)
            }
            .padding(.vertical, 32)
        }
        .presentationDetents([.height(400)])
        .presentationDragIndicator(.visible)
        .presentationBackground(FanChatTheme.backgroundPrimary)
        .preferredColorScheme(.dark)
    }
}

#Preview("Report Sheet") {
    CasinoReportSheet(
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
    CasinoBlockConfirmationSheet(
        anonymousName: "Blue Tiger",
        onConfirm: { print("Blocked") }
    )
}
