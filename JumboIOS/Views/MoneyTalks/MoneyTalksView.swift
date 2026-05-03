import SwiftUI

struct MoneyTalksView: View {
    @StateObject private var viewModel = MoneyTalksViewModel()
    @State private var showingCreateRoom = false

    var body: some View {
        NavigationStack {
            ZStack {
                FanChatTheme.backgroundPrimary
                    .ignoresSafeArea()

                NoiseBackground()
                    .opacity(0.3)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    // Header
                    headerSection
                        .background(FanChatTheme.backgroundPrimary)

                    // Room cards
                    ScrollView {
                        LazyVStack(spacing: 14) {
                            ForEach(Array(viewModel.rooms.enumerated()), id: \.element.id) { index, room in
                                NavigationLink {
                                    MoneyRoomDetailView(room: room)
                                } label: {
                                    MoneyRoomCard(room: room, viewModel: viewModel)
                                }
                                .buttonStyle(.plain)
                                .slideIn(delay: Double(index) * 0.06)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                        .padding(.bottom, 40)
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .navigationBarHidden(true)
            .sheet(isPresented: $showingCreateRoom) {
                CreateRoomSheet(viewModel: viewModel)
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Money Talks")
                        .font(.system(size: 28, weight: .black))
                        .foregroundColor(FanChatTheme.textPrimary)

                    Text("Put your money where your mouth is")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(FanChatTheme.textSecondary)
                }

                Spacer()

                // Create Room button
                Button {
                    let generator = UIImpactFeedbackGenerator(style: .medium)
                    generator.impactOccurred()
                    showingCreateRoom = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .bold))
                        Text("Create")
                            .font(.system(size: 14, weight: .bold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [FanChatTheme.neonGreen, FanChatTheme.neonCyan],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                    )
                }
            }

            // Stats bar
            HStack(spacing: 20) {
                StatPill(label: "Rooms", value: "\(viewModel.rooms.count)", color: FanChatTheme.neonCyan)
                StatPill(label: "Live", value: "\(viewModel.rooms.filter { $0.status == .live }.count)", color: FanChatTheme.liveIndicator)
                StatPill(label: "Open", value: "\(viewModel.rooms.filter { $0.status == .open }.count)", color: FanChatTheme.neonGreen)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }
}

// MARK: - Stat Pill

private struct StatPill: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Text(value)
                .font(.system(size: 16, weight: .black, design: .rounded))
                .foregroundColor(color)

            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(FanChatTheme.textTertiary)
        }
    }
}

// MARK: - Money Room Card

struct MoneyRoomCard: View {
    let room: MoneyRoom
    let viewModel: MoneyTalksViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Top section: emoji, title, status
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(room.accentColor.opacity(0.15))
                        .frame(width: 48, height: 48)

                    Text(room.emoji)
                        .font(.system(size: 24))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(room.title)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(FanChatTheme.textPrimary)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text("by \(room.hostName)")
                            .font(.system(size: 12))
                            .foregroundColor(FanChatTheme.textTertiary)

                        Text("•")
                            .foregroundColor(FanChatTheme.textTertiary)

                        HStack(spacing: 4) {
                            Circle()
                                .fill(room.status.color)
                                .frame(width: 6, height: 6)

                            Text(room.status.rawValue)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(room.status.color)
                        }
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 14)

            // Divider
            Rectangle()
                .fill(FanChatTheme.backgroundTertiary)
                .frame(height: 1)
                .padding(.horizontal, 16)

            // Bottom section: stats + join
            HStack(spacing: 0) {
                // Entry fee
                VStack(spacing: 2) {
                    Text(viewModel.formattedCurrency(room.entryFee))
                        .font(.system(size: 18, weight: .black, design: .rounded))
                        .foregroundColor(FanChatTheme.textPrimary)
                    Text("entry")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(FanChatTheme.textTertiary)
                }
                .frame(maxWidth: .infinity)

                // Divider
                Rectangle()
                    .fill(FanChatTheme.backgroundTertiary)
                    .frame(width: 1, height: 32)

                // Prize pool (entry × participants)
                VStack(spacing: 2) {
                    Text(viewModel.formattedCurrency(livePrizePool))
                        .font(.system(size: 18, weight: .black, design: .rounded))
                        .foregroundColor(FanChatTheme.neonGreen)
                    Text("prize")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(FanChatTheme.textTertiary)
                }
                .frame(maxWidth: .infinity)

                // Divider
                Rectangle()
                    .fill(FanChatTheme.backgroundTertiary)
                    .frame(width: 1, height: 32)

                // Participants
                VStack(spacing: 2) {
                    Text("\(room.participants)/\(room.maxParticipants)")
                        .font(.system(size: 18, weight: .black, design: .rounded))
                        .foregroundColor(FanChatTheme.textPrimary)
                    Text("players")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(FanChatTheme.textTertiary)
                }
                .frame(maxWidth: .infinity)

                // Join button
                Button {
                    let generator = UIImpactFeedbackGenerator(style: .medium)
                    generator.impactOccurred()
                } label: {
                    Text(room.status == .closed ? "Full" : "Join")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(room.status == .closed ? FanChatTheme.textTertiary : .white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(
                            Capsule()
                                .fill(room.status == .closed ?
                                      AnyShapeStyle(FanChatTheme.backgroundTertiary) :
                                      AnyShapeStyle(LinearGradient(
                                        colors: [room.accentColor, room.accentColor.opacity(0.7)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                      )))
                        )
                }
                .disabled(room.status == .closed)
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 14)

            // Payout row
            HStack(spacing: 0) {
                HStack(spacing: 1) {
                    Text("🥇 ").font(.system(size: 10))
                    Text(viewModel.formattedCurrency(livePrizePool * 0.5))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(FanChatTheme.neonYellow)
                }

                Spacer()

                HStack(spacing: 1) {
                    Text("🥈 ").font(.system(size: 10))
                    Text(viewModel.formattedCurrency(livePrizePool * 0.3))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(FanChatTheme.textSecondary)
                }

                Spacer()

                HStack(spacing: 1) {
                    Text("🥉 ").font(.system(size: 10))
                    Text(viewModel.formattedCurrency(livePrizePool * 0.2))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(FanChatTheme.neonOrange)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            // Capacity bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(FanChatTheme.backgroundTertiary)
                        .frame(height: 3)

                    RoundedRectangle(cornerRadius: 2)
                        .fill(capacityColor)
                        .frame(width: geo.size.width * capacityRatio, height: 3)
                }
            }
            .frame(height: 3)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(FanChatTheme.cardGradient)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(
                    room.status == .live ? room.accentColor.opacity(0.3) : FanChatTheme.backgroundTertiary,
                    lineWidth: 1
                )
        )
    }

    private var livePrizePool: Double {
        room.entryFee * Double(room.participants)
    }

    private var capacityRatio: CGFloat {
        CGFloat(room.participants) / CGFloat(room.maxParticipants)
    }

    private var capacityColor: Color {
        if capacityRatio >= 0.9 { return FanChatTheme.neonPink }
        if capacityRatio >= 0.7 { return FanChatTheme.neonYellow }
        return FanChatTheme.neonGreen
    }
}

// MARK: - Create Room Sheet

struct CreateRoomSheet: View {
    @ObservedObject var viewModel: MoneyTalksViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var description = ""
    @State private var entryFee: Double = 5
    @State private var durationMinutes: Double = 30
    @FocusState private var titleFocused: Bool

    private let maxTitleLength = 40
    private let maxDescriptionLength = 120

    private var canCreate: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3
    }

    private var estimatedPrize: Double {
        let maxParticipants = entryFee >= 10 ? 50.0 : 40.0
        return entryFee * maxParticipants * 0.9
    }

    private var formattedDuration: String {
        let mins = Int(durationMinutes)
        if mins >= 60 {
            let hours = mins / 60
            let remaining = mins % 60
            return remaining > 0 ? "\(hours)h \(remaining)m" : "\(hours)h"
        }
        return "\(mins)m"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                FanChatTheme.backgroundPrimary
                    .ignoresSafeArea()

                NoiseBackground()
                    .opacity(0.3)
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {
                        // Title input
                        inputSection(header: "ROOM TITLE") {
                            HStack {
                                TextField("e.g. NFL Sunday Showdown", text: $title)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 17, weight: .medium))
                                    .foregroundColor(FanChatTheme.textPrimary)
                                    .focused($titleFocused)
                                    .autocorrectionDisabled()
                                    .onChange(of: title) { _, newValue in
                                        if newValue.count > maxTitleLength {
                                            title = String(newValue.prefix(maxTitleLength))
                                        }
                                    }

                                Text("\(title.count)/\(maxTitleLength)")
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundColor(title.count >= maxTitleLength ? FanChatTheme.neonOrange : FanChatTheme.textTertiary)
                            }
                        }

                        // Description input
                        inputSection(header: "TOPIC / DESCRIPTION") {
                            ZStack(alignment: .topLeading) {
                                if description.isEmpty {
                                    Text("What's this room about?")
                                        .font(.system(size: 16))
                                        .foregroundColor(FanChatTheme.textTertiary)
                                        .padding(.top, 8)
                                        .padding(.leading, 2)
                                }

                                TextEditor(text: $description)
                                    .font(.system(size: 16))
                                    .foregroundColor(FanChatTheme.textPrimary)
                                    .frame(minHeight: 70, maxHeight: 100)
                                    .scrollContentBackground(.hidden)
                                    .background(Color.clear)
                                    .onChange(of: description) { _, newValue in
                                        if newValue.count > maxDescriptionLength {
                                            description = String(newValue.prefix(maxDescriptionLength))
                                        }
                                    }
                            }

                            HStack {
                                Spacer()
                                Text("\(description.count)/\(maxDescriptionLength)")
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundColor(description.count >= maxDescriptionLength ? FanChatTheme.neonOrange : FanChatTheme.textTertiary)
                            }
                        }

                        // Entry fee slider
                        VStack(alignment: .leading, spacing: 10) {
                            Text("ENTRY FEE")
                                .font(.system(size: 11, weight: .black))
                                .foregroundColor(FanChatTheme.textTertiary)
                                .tracking(2)

                            HStack {
                                Text(viewModel.formattedCurrency(entryFee))
                                    .font(.system(size: 28, weight: .black, design: .rounded))
                                    .foregroundColor(FanChatTheme.textPrimary)

                                Spacer()

                                VStack(alignment: .trailing, spacing: 2) {
                                    Text("est. prize")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundColor(FanChatTheme.textTertiary)
                                    Text(viewModel.formattedCurrency(estimatedPrize))
                                        .font(.system(size: 16, weight: .bold, design: .rounded))
                                        .foregroundColor(FanChatTheme.neonGreen)
                                }
                            }

                            Slider(value: $entryFee, in: 1...50, step: 1)
                                .tint(
                                    LinearGradient(
                                        colors: [FanChatTheme.neonGreen, FanChatTheme.neonCyan],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )

                            HStack {
                                Text("$1")
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .foregroundColor(FanChatTheme.textSecondary)
                                Spacer()
                                Text("$50")
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .foregroundColor(FanChatTheme.textSecondary)
                            }
                        }
                        .padding(16)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(FanChatTheme.backgroundSecondary)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(FanChatTheme.backgroundTertiary, lineWidth: 1)
                        )

                        // Duration slider
                        VStack(alignment: .leading, spacing: 10) {
                            Text("DURATION")
                                .font(.system(size: 11, weight: .black))
                                .foregroundColor(FanChatTheme.textTertiary)
                                .tracking(2)

                            Text(formattedDuration)
                                .font(.system(size: 28, weight: .black, design: .rounded))
                                .foregroundColor(FanChatTheme.textPrimary)

                            Slider(value: $durationMinutes, in: 10...120, step: 5)
                                .tint(
                                    LinearGradient(
                                        colors: [FanChatTheme.neonOrange, FanChatTheme.neonPink],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )

                            HStack {
                                Text("10m")
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .foregroundColor(FanChatTheme.textSecondary)
                                Spacer()
                                Text("2h")
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .foregroundColor(FanChatTheme.textSecondary)
                            }
                        }
                        .padding(16)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(FanChatTheme.backgroundSecondary)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(FanChatTheme.backgroundTertiary, lineWidth: 1)
                        )

                        // Summary card
                        VStack(spacing: 12) {
                            HStack {
                                Text("ROOM SUMMARY")
                                    .font(.system(size: 11, weight: .black))
                                    .foregroundColor(FanChatTheme.textTertiary)
                                    .tracking(2)
                                Spacer()
                            }

                            HStack(spacing: 0) {
                                VStack(spacing: 2) {
                                    Text(viewModel.formattedCurrency(entryFee))
                                        .font(.system(size: 18, weight: .black, design: .rounded))
                                        .foregroundColor(FanChatTheme.textPrimary)
                                    Text("entry")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundColor(FanChatTheme.textTertiary)
                                }
                                .frame(maxWidth: .infinity)

                                Rectangle()
                                    .fill(FanChatTheme.backgroundTertiary)
                                    .frame(width: 1, height: 30)

                                VStack(spacing: 2) {
                                    Text(viewModel.formattedCurrency(estimatedPrize))
                                        .font(.system(size: 18, weight: .black, design: .rounded))
                                        .foregroundColor(FanChatTheme.neonGreen)
                                    Text("prize pool")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundColor(FanChatTheme.textTertiary)
                                }
                                .frame(maxWidth: .infinity)

                                Rectangle()
                                    .fill(FanChatTheme.backgroundTertiary)
                                    .frame(width: 1, height: 30)

                                VStack(spacing: 2) {
                                    Text(formattedDuration)
                                        .font(.system(size: 18, weight: .black, design: .rounded))
                                        .foregroundColor(FanChatTheme.textPrimary)
                                    Text("duration")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundColor(FanChatTheme.textTertiary)
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }
                        .padding(16)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(FanChatTheme.backgroundSecondary)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(FanChatTheme.neonGreen.opacity(canCreate ? 0.2 : 0), lineWidth: 1)
                        )
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                    .padding(.bottom, 40)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("Create Room")
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

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        let generator = UINotificationFeedbackGenerator()
                        generator.notificationOccurred(.success)
                        viewModel.createRoom(
                            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                            entryFee: entryFee,
                            durationMinutes: Int(durationMinutes)
                        )
                        dismiss()
                    } label: {
                        Text("Create")
                    }
                    .foregroundColor(canCreate ? FanChatTheme.neonGreen : FanChatTheme.textTertiary)
                    .disabled(!canCreate)
                }
            }
            .onAppear {
                titleFocused = true
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(FanChatTheme.backgroundPrimary)
        .preferredColorScheme(.dark)
    }

    // MARK: - Input Section Helper

    private func inputSection<Content: View>(header: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(header)
                .font(.system(size: 11, weight: .black))
                .foregroundColor(FanChatTheme.textTertiary)
                .tracking(2)

            VStack(alignment: .leading, spacing: 4) {
                content()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(FanChatTheme.backgroundSecondary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(FanChatTheme.backgroundTertiary, lineWidth: 1)
            )
        }
    }
}

#Preview {
    MoneyTalksView()
}
