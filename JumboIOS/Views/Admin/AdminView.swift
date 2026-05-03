import SwiftUI
import Combine

struct AdminView: View {
    @StateObject private var viewModel = AdminViewModel()
    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            // Tab selector
            Picker("View", selection: $selectedTab) {
                Text("Reports").tag(0)
                Text("Flagged Posts").tag(1)
                Text("Stats").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            TabView(selection: $selectedTab) {
                // Reports Queue
                reportsView
                    .tag(0)

                // Flagged Posts
                flaggedPostsView
                    .tag(1)

                // Stats Dashboard
                statsView
                    .tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Admin Panel")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.loadData()
        }
        .refreshable {
            await viewModel.loadData()
        }
    }

    // MARK: - Reports View
    private var reportsView: some View {
        Group {
            if viewModel.isLoading {
                loadingView
            } else if viewModel.pendingReports.isEmpty {
                emptyReportsView
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(viewModel.pendingReports) { report in
                            ReportCard(
                                report: report,
                                post: viewModel.getPost(for: report.postId),
                                onDismiss: {
                                    Task { await viewModel.resolveReport(report, resolution: .dismissed) }
                                },
                                onRemovePost: {
                                    Task { await viewModel.resolveReport(report, resolution: .postRemoved) }
                                },
                                onWarnUser: {
                                    Task { await viewModel.resolveReport(report, resolution: .userWarned) }
                                }
                            )
                        }
                    }
                    .padding(16)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    // MARK: - Flagged Posts View
    private var flaggedPostsView: some View {
        Group {
            if viewModel.flaggedPosts.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "flag.slash")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)

                    Text("No flagged posts")
                        .font(.headline)

                    Text("Posts with multiple reports will appear here")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(viewModel.flaggedPosts) { post in
                            FlaggedPostCard(
                                post: post,
                                onHide: {
                                    Task { await viewModel.hidePost(post) }
                                },
                                onDelete: {
                                    Task { await viewModel.deletePost(post) }
                                },
                                onApprove: {
                                    Task { await viewModel.approvePost(post) }
                                }
                            )
                        }
                    }
                    .padding(16)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    // MARK: - Stats View
    private var statsView: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Overview cards
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 12) {
                    StatCard(
                        title: "Total Posts",
                        value: "\(viewModel.totalPosts)",
                        icon: "bubble.left.fill",
                        color: .blue
                    )

                    StatCard(
                        title: "Active Users",
                        value: "\(viewModel.activeUsers)",
                        icon: "person.2.fill",
                        color: .green
                    )

                    StatCard(
                        title: "Reports Today",
                        value: "\(viewModel.reportsToday)",
                        icon: "flag.fill",
                        color: .orange
                    )

                    StatCard(
                        title: "Posts Hidden",
                        value: "\(viewModel.hiddenPosts)",
                        icon: "eye.slash.fill",
                        color: .red
                    )
                }

                // Recent activity
                VStack(alignment: .leading, spacing: 12) {
                    Text("Recent Activity")
                        .font(.system(size: 15, weight: .semibold))

                    VStack(spacing: 8) {
                        ActivityRow(icon: "flag.fill", color: .orange, text: "5 new reports in last hour")
                        ActivityRow(icon: "bubble.left.fill", color: .blue, text: "127 posts in last hour")
                        ActivityRow(icon: "hand.thumbsup.fill", color: .green, text: "342 votes in last hour")
                        ActivityRow(icon: "person.badge.plus", color: .purple, text: "23 new users today")
                    }
                    .padding(12)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)
                }
            }
            .padding(16)
        }
        .scrollIndicators(.hidden)
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Loading reports...")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyReportsView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 48))
                .foregroundColor(.green)

            Text("All clear!")
                .font(.headline)

            Text("No pending reports to review")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Report Card
struct ReportCard: View {
    let report: Report
    let post: Post?
    let onDismiss: () -> Void
    let onRemovePost: () -> Void
    let onWarnUser: () -> Void

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Label(report.reason.rawValue, systemImage: "flag.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.orange)

                Spacer()

                Text(timeAgo(from: report.createdAt))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            // Post content
            if let post = post {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(post.anonymousName)
                            .font(.system(size: 13, weight: .medium))

                        if post.reportCount > 1 {
                            Text("\(post.reportCount) reports")
                                .font(.system(size: 11))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.red))
                        }
                    }

                    Text(post.content)
                        .font(.system(size: 14))
                        .lineLimit(isExpanded ? nil : 3)
                        .onTapGesture {
                            withAnimation { isExpanded.toggle() }
                        }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.tertiarySystemBackground))
                .cornerRadius(8)
            }

            // Additional info
            if let info = report.additionalInfo, !info.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Reporter's note:")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)

                    Text(info)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
            }

            // Actions
            HStack(spacing: 8) {
                Button(action: onDismiss) {
                    Label("Dismiss", systemImage: "xmark")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(.tertiarySystemBackground))
                        .cornerRadius(8)
                }

                Button(action: onWarnUser) {
                    Label("Warn", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.orange)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(8)
                }

                Spacer()

                Button(action: onRemovePost) {
                    Label("Remove", systemImage: "trash")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.red)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(8)
                }
            }
        }
        .padding(16)
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.05), radius: 4, x: 0, y: 2)
    }

    private func timeAgo(from date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400))d ago"
    }
}

// MARK: - Flagged Post Card
struct FlaggedPostCard: View {
    let post: Post
    let onHide: () -> Void
    let onDelete: () -> Void
    let onApprove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HStack(spacing: 4) {
                    Image(systemName: "flag.fill")
                    Text("\(post.reportCount) reports")
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.red)

                Spacer()

                if post.isHidden {
                    Text("HIDDEN")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.orange.opacity(0.2))
                        .cornerRadius(4)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(post.anonymousName)
                    .font(.system(size: 13, weight: .medium))

                Text(post.content)
                    .font(.system(size: 14))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.tertiarySystemBackground))
            .cornerRadius(8)

            HStack(spacing: 8) {
                Button(action: onApprove) {
                    Label("Approve", systemImage: "checkmark")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.green)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.green.opacity(0.1))
                        .cornerRadius(8)
                }

                Button(action: onHide) {
                    Label("Hide", systemImage: "eye.slash")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.orange)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(8)
                }

                Spacer()

                Button(action: onDelete) {
                    Label("Delete", systemImage: "trash")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.red)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(8)
                }
            }
        }
        .padding(16)
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.05), radius: 4, x: 0, y: 2)
    }
}

// MARK: - Stat Card
struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(color)

                Spacer()
            }

            Text(value)
                .font(.system(size: 28, weight: .bold))

            Text(title)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .padding(16)
        .background(Color(.systemBackground))
        .cornerRadius(12)
    }
}

// MARK: - Activity Row
struct ActivityRow: View {
    let icon: String
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(color)
                .frame(width: 24)

            Text(text)
                .font(.system(size: 13))
                .foregroundColor(.primary)

            Spacer()
        }
    }
}

// MARK: - View Model
@MainActor
class AdminViewModel: ObservableObject {
    @Published var reports: [Report] = []
    @Published var isLoading = false

    // Backed by `AppServices.shared.chatService` — see AppServices.swift.
    let service: any ChatServiceProtocol = AppServices.shared.chatService

    var pendingReports: [Report] {
        reports.filter { !$0.isResolved }
    }

    var flaggedPosts: [Post] {
        service.posts.filter { $0.reportCount >= 3 || $0.isHidden }
    }

    // Stats (mock data)
    var totalPosts: Int { service.posts.count }
    var activeUsers: Int { 47 }
    var reportsToday: Int { reports.count }
    var hiddenPosts: Int { service.posts.filter { $0.isHidden }.count }

    func loadData() async {
        isLoading = true
        do {
            reports = try await service.fetchReports()
        } catch {
            print("Error loading reports: \(error)")
        }
        isLoading = false
    }

    func getPost(for postId: UUID) -> Post? {
        service.getPost(by: postId)
    }

    func resolveReport(_ report: Report, resolution: ReportResolution) async {
        do {
            try await service.resolveReport(report.id, resolution: resolution)
            await loadData()
        } catch {
            print("Error resolving report: \(error)")
        }
    }

    func hidePost(_ post: Post) async {
        do {
            try await service.hidePost(post.id)
        } catch {
            print("Error hiding post: \(error)")
        }
    }

    func deletePost(_ post: Post) async {
        do {
            try await service.deletePost(post.id)
        } catch {
            print("Error deleting post: \(error)")
        }
    }

    func approvePost(_ post: Post) async {
        do {
            try await service.approvePost(post.id)
        } catch {
            print("Error approving post: \(error)")
        }
    }
}

#Preview {
    NavigationStack {
        AdminView()
    }
}
