// Path: Views/Analytics/AnalyticsDashboardView.swift
import SwiftUI
import SwiftData

// MARK: - Main Dashboard

public struct AnalyticsDashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \DriveSession.startTime, order: .reverse) private var sessions: [DriveSession]
    @StateObject private var viewModel = AnalyticsViewModel()

    public init() {}

    public var body: some View {
        ZStack {
            DesignSystem.bgDeep.ignoresSafeArea()

            VStack(spacing: 0) {
                // ── Header ──────────────────────────────────────────────
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: -4) {
                        Text("Analysis")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                        
                        Text("Drive Insights")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundColor(DesignSystem.cyan.opacity(0.8))
                    }

                    Spacer()

                    // Premium "Select Session" button
                    Button {
                        viewModel.showSessionPicker = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 14, weight: .bold))
                            Text("Sessions")
                                .font(.system(size: 14, weight: .bold))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            ZStack {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(DesignSystem.cyan.opacity(0.15))
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(DesignSystem.cyan.opacity(0.3), lineWidth: 1.5)
                            }
                        )
                        .foregroundColor(DesignSystem.cyan)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 16)

                // ── Content ─────────────────────────────────────────────
                if let session = viewModel.selectedSession {
                    AnalyticsContentView(session: session, viewModel: viewModel)
                } else {
                    AnalyticsEmptyState(hasSessions: !sessions.isEmpty) {
                        viewModel.showSessionPicker = true
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            // Auto-purge sessions older than 30 days (non-starred)
            viewModel.purgeOldSessions(sessions: sessions, context: modelContext)
            // Auto-select most recent session if none selected
            if viewModel.selectedSession == nil, let first = sessions.first {
                viewModel.selectSession(first)
            }
        }
        // Bottom sheet session picker
        .sheet(isPresented: $viewModel.showSessionPicker) {
            SessionPickerSheet(sessions: sessions, viewModel: viewModel)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(24)
                .preferredColorScheme(.dark)
        }
    }
}

// MARK: - Analytics Content (when a session is selected)

private struct AnalyticsContentView: View {
    let session: DriveSession
    @ObservedObject var viewModel: AnalyticsViewModel
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Session title banner
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.title)
                            .font(.headline.weight(.semibold))
                            .foregroundColor(.white)
                        Text(session.startTime.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundColor(.gray)
                    }
                    Spacer()
                    
                    Button {
                        withAnimation(.spring()) {
                            viewModel.toggleStar(session, context: modelContext)
                        }
                    } label: {
                        Image(systemName: session.isStarred ? "star.fill" : "star")
                            .font(.title3)
                            .foregroundColor(session.isStarred ? .yellow : .gray.opacity(0.4))
                            .frame(width: 44, height: 44)
                            .background(
                                Circle()
                                    .fill(session.isStarred ? Color.yellow.opacity(0.12) : Color.white.opacity(0.05))
                            )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)

                // Score + Time Distribution
                HStack(spacing: 16) {
                    DrivingScoreView(score: viewModel.drivingScore)
                        .frame(maxWidth: .infinity)
                        .frame(height: 200)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("TIME DISTRIBUTION")
                            .font(DesignSystem.labelFont)
                            .foregroundColor(.gray)

                        GeometryReader { proxy in
                            HStack(spacing: 0) {
                                Rectangle()
                                    .fill(DesignSystem.neonGreen)
                                    .frame(width: proxy.size.width * CGFloat(session.percentWithinLimit))
                                Rectangle()
                                    .fill(DesignSystem.alertRed)
                                    .frame(width: proxy.size.width * CGFloat(1.0 - session.percentWithinLimit))
                            }
                            .cornerRadius(8)
                        }
                        .frame(height: 16)

                        HStack {
                            Circle().fill(DesignSystem.neonGreen).frame(width: 8)
                            Text("Safe").font(.caption).foregroundColor(.gray)
                            Spacer()
                            Circle().fill(DesignSystem.alertRed).frame(width: 8)
                            Text("Over").font(.caption).foregroundColor(.gray)
                        }
                    }
                    .padding()
                    .background(DesignSystem.bgPanel)
                    .cornerRadius(16)
                    .frame(maxWidth: .infinity)
                    .frame(height: 200)
                }
                .padding(.horizontal)

                SummaryStatsView(viewModel: viewModel)
                    .padding(.horizontal)

                OverspeedHeatMapView(session: session)
                    .frame(height: 320)
                    .cornerRadius(16)
                    .padding(.horizontal)
            }
            .padding(.bottom, 30)
        }
    }
}

// MARK: - Empty State

private struct AnalyticsEmptyState: View {
    let hasSessions: Bool
    let onTap: () -> Void

    var body: some View {
        Spacer()
        VStack(spacing: 20) {
            Image(systemName: hasSessions ? "list.bullet.rectangle.portrait" : "car.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(DesignSystem.bgCard)
            Text(hasSessions ? "Tap \"Select Session\" to view a drive" : "No drives recorded yet.")
                .font(.headline)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
            if hasSessions {
                Button("Select Session", action: onTap)
                    .foregroundColor(DesignSystem.cyan)
                    .padding(.top, 4)
            }
        }
        .padding()
        Spacer()
    }
}

// MARK: - Session Picker Sheet

private struct SessionPickerSheet: View {
    let sessions: [DriveSession]
    @ObservedObject var viewModel: AnalyticsViewModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    // Starred sessions first, then by date descending
    private var sortedSessions: [DriveSession] {
        sessions.sorted {
            if $0.isStarred != $1.isStarred { return $0.isStarred }
            return $0.startTime > $1.startTime
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Drag handle area
            Capsule()
                .fill(Color.gray.opacity(0.3))
                .frame(width: 40, height: 4)
                .padding(.top, 12)
            
            // Sheet header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Select Session")
                        .font(.title2.weight(.bold))
                        .foregroundColor(.white)
                    Text("Tap to open • Hold for options")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.gray.opacity(0.5))
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 12)

            // 30-day note
            HStack(spacing: 6) {
                Image(systemName: "calendar.badge.clock")
                    .font(.caption)
                Text("Unstarred sessions are automatically removed after 30 days.")
                    .font(.caption)
            }
            .foregroundColor(DesignSystem.cyan.opacity(0.7))
            .padding(.horizontal, 24)
            .padding(.bottom, 16)

            Divider().background(Color.gray.opacity(0.1))

            if sortedSessions.isEmpty {
                Spacer()
                VStack(spacing: 16) {
                    Image(systemName: "car.circle.fill")
                        .font(.system(size: 64))
                        .foregroundColor(DesignSystem.bgCard)
                    Text("No saved drive sessions found.")
                        .font(.headline)
                        .foregroundColor(.gray)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if !sortedSessions.filter({ $0.isStarred }).isEmpty {
                            SectionLabel(title: "Starred Favorites")
                        }

                        ForEach(sortedSessions.filter { $0.isStarred }) { session in
                            SessionRow(session: session, viewModel: viewModel)
                        }

                        if !sortedSessions.filter({ !$0.isStarred }).isEmpty {
                            SectionLabel(title: "Recent Rides")
                        }

                        ForEach(sortedSessions.filter { !$0.isStarred }) { session in
                            SessionRow(session: session, viewModel: viewModel)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 30)
                }
            }
        }
        .background(DesignSystem.bgDeep.ignoresSafeArea())
    }
}

// MARK: - Section Label

private struct SectionLabel: View {
    let title: String
    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundColor(.gray)
                .tracking(1.2)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }
}

// MARK: - Session Row (tap + long-press)

private struct SessionRow: View {
    let session: DriveSession
    @ObservedObject var viewModel: AnalyticsViewModel
    @Environment(\.modelContext) private var modelContext
    @State private var showContextMenu = false

    private var daysLeft: Int? {
        guard !session.isStarred else { return nil }
        let expiry = Calendar.current.date(byAdding: .day, value: 30, to: session.startTime) ?? session.startTime
        let days = Calendar.current.dateComponents([.day], from: Date(), to: expiry).day ?? 0
        return max(0, days)
    }

    var body: some View {
        Button {
            viewModel.selectSession(session)
        } label: {
            HStack(spacing: 14) {
                // Score ring
                ZStack {
                    Circle()
                        .stroke(scoreColor(session.drivingScore).opacity(0.25), lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: CGFloat(session.drivingScore) / 100)
                        .stroke(scoreColor(session.drivingScore), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(session.drivingScore)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(scoreColor(session.drivingScore))
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        if session.isStarred {
                            Image(systemName: "star.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.yellow)
                        }
                        Text(session.title)
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(.white)
                            .lineLimit(1)
                    }
                    HStack(spacing: 8) {
                        Text(session.startTime.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundColor(.gray)
                        if let days = daysLeft {
                            Text("·")
                                .foregroundColor(.gray)
                            Text(days == 0 ? "Expires today" : "Expires in \(days)d")
                                .font(.caption)
                                .foregroundColor(days <= 3 ? .orange : .gray.opacity(0.7))
                        }
                    }
                }

                Spacer()

                // Active indicator
                if viewModel.selectedSession?.id == session.id {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(DesignSystem.cyan)
                        .font(.system(size: 18))
                }

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.gray.opacity(0.5))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(viewModel.selectedSession?.id == session.id
                          ? DesignSystem.cyan.opacity(0.12)
                          : DesignSystem.bgCard.opacity(0.6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(viewModel.selectedSession?.id == session.id ? DesignSystem.cyan.opacity(0.4) : Color.white.opacity(0.05), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                viewModel.selectSession(session)
            } label: {
                Label("Open Analysis", systemImage: "chart.bar.fill")
            }

            Button {
                viewModel.toggleStar(session, context: modelContext)
            } label: {
                Label(session.isStarred ? "Unstar" : "Star Session",
                      systemImage: session.isStarred ? "star.slash" : "star.fill")
            }

            Divider()

            Button(role: .destructive) {
                viewModel.deleteSession(session, context: modelContext)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func scoreColor(_ score: Int) -> Color {
        switch score {
        case 80...100: return DesignSystem.neonGreen
        case 60..<80:  return .yellow
        default:       return DesignSystem.alertRed
        }
    }
}
