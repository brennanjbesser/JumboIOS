import SwiftUI

struct NewPostView: View {
    @ObservedObject var preferences: UserPreferences
    let onPost: (String, UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var content = ""
    @State private var selectedTeam: SportsTeam?
    @State private var isPosting = false
    @FocusState private var isTextFieldFocused: Bool

    private let maxCharacters = 280

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Team selector
                teamSelector
                    .padding(16)

                Divider()

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
                        if let team = selectedTeam {
                            HStack(spacing: 6) {
                                Text("Posting to")
                                    .foregroundColor(.secondary)
                                Text(team.fullName)
                                    .fontWeight(.medium)
                            }
                            .font(.system(size: 13))
                        }

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
            .navigationTitle("New Post")
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
                // Default to first followed team
                selectedTeam = preferences.followedTeams.first
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Team Selector
    private var teamSelector: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Select Team")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(preferences.followedTeams) { team in
                        TeamSelectButton(
                            team: team,
                            isSelected: selectedTeam?.id == team.id
                        ) {
                            selectedTeam = team
                        }
                    }
                }
            }
        }
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
        return trimmed.count >= 2 && trimmed.count <= maxCharacters && !isPosting && selectedTeam != nil
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
        guard canPost, let team = selectedTeam else { return }

        isPosting = true
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)

        onPost(trimmedContent, team.id)
        dismiss()
    }
}

// MARK: - Team Select Button
struct TeamSelectButton: View {
    let team: SportsTeam
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [team.primaryColor, team.secondaryColor],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 32, height: 32)

                    Text(team.logoEmoji)
                        .font(.system(size: 16))
                }

                Text(team.shortName)
                    .font(.system(size: 14, weight: .semibold))

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.green)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? team.primaryColor.opacity(0.15) : Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? team.primaryColor : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    NewPostView(preferences: UserPreferences.shared) { content, teamId in
        print("Posted: \(content) to team: \(teamId)")
    }
}
