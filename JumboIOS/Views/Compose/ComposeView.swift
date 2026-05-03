import SwiftUI

struct ComposeView: View {
    let gameId: UUID?
    let onPost: (String) -> Void
    let parentPost: Post?

    @Environment(\.dismiss) private var dismiss
    @State private var content = ""
    @State private var isPosting = false
    @FocusState private var isTextFieldFocused: Bool

    private let maxCharacters = 280

    init(gameId: UUID? = nil, parentPost: Post? = nil, onPost: @escaping (String) -> Void) {
        self.gameId = gameId
        self.parentPost = parentPost
        self.onPost = onPost
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Reply context if replying
                if let parent = parentPost {
                    replyContext(parent)
                }

                // Text editor
                VStack(alignment: .leading, spacing: 12) {
                    TextEditor(text: $content)
                        .font(.system(size: 18))
                        .frame(minHeight: 120)
                        .focused($isTextFieldFocused)
                        .scrollContentBackground(.hidden)

                    Divider()

                    // Character count
                    HStack {
                        Spacer()

                        Text("\(content.count)/\(maxCharacters)")
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundColor(characterCountColor)
                    }
                }
                .padding(16)

                Spacer()

                // Guidelines
                guidelinesView
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            }
            .background(Color(.systemBackground))
            .navigationTitle(parentPost != nil ? "Reply" : "New Post")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        post()
                    } label: {
                        if isPosting {
                            ProgressView()
                        } else {
                            Text("Post")
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(!canPost)
                }
            }
            .onAppear {
                isTextFieldFocused = true
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func replyContext(_ parent: Post) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 3)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Replying to \(parent.anonymousName)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)

                    Text(parent.content)
                        .font(.system(size: 14))
                        .foregroundColor(.primary)
                        .lineLimit(2)
                }
            }
            .padding(12)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
        }
        .padding(16)
    }

    private var guidelinesView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Community Guidelines")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "shield.checkered")
                    .font(.system(size: 14))
                    .foregroundColor(.accentColor)

                Text("Keep it fun and respectful. No hate speech, harassment, or spam. Posts are anonymous but moderated.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .background(Color(.tertiarySystemBackground))
        .cornerRadius(12)
    }

    private var canPost: Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= 2 && trimmed.count <= maxCharacters && !isPosting
    }

    private var characterCountColor: Color {
        if content.count > maxCharacters {
            return .red
        } else if content.count > maxCharacters - 20 {
            return .orange
        }
        return .secondary
    }

    private func post() {
        guard canPost else { return }

        isPosting = true
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)

        onPost(trimmedContent)
        dismiss()
    }
}

// MARK: - Quick Reply Bar
struct QuickReplyBar: View {
    let placeholder: String
    @Binding var text: String
    let onSend: () -> Void
    let isSending: Bool

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .lineLimit(1...4)
                .focused($isFocused)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color(.secondarySystemBackground))
                )

            Button(action: onSend) {
                if isSending {
                    ProgressView()
                        .frame(width: 36, height: 36)
                } else {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 36))
                        .foregroundColor(canSend ? .accentColor : .secondary)
                }
            }
            .disabled(!canSend)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            Color(.systemBackground)
                .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: -4)
        )
    }

    private var canSend: Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= 2 && trimmed.count <= 280 && !isSending
    }
}

#Preview("New Post") {
    ComposeView(gameId: nil) { content in
        print("Posted: \(content)")
    }
}

#Preview("Reply") {
    ComposeView(
        gameId: nil,
        parentPost: Post.preview(
            authorId: UUID(),
            content: "MAHOMES IS COOKING 🔥🔥🔥",
            upvotes: 42,
            downvotes: 3
        )
    ) { content in
        print("Replied: \(content)")
    }
}
