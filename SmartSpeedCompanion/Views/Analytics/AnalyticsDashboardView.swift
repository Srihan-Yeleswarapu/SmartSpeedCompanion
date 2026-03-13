// Path: Views/Analytics/AnalyticsDashboardView.swift
import SwiftUI
import SwiftData

public struct AnalyticsDashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) var sizeClass
    @Query(sort: \DriveSession.startTime, order: .reverse) private var sessions: [DriveSession]
    @StateObject private var viewModel = AnalyticsViewModel()
    
    public init() {}
    
    public var body: some View {
        NavigationStack {
            ZStack {
                DesignSystem.bgDeep.ignoresSafeArea()
                
                VStack(spacing: 0) {
                    // Header
                    HStack {
                        Text("ANALYTICS")
                            .font(DesignSystem.displayFont)
                            .scaleEffect(0.6, anchor: .leading)
                            .frame(height: 30) // Hack to size Orbitron
                        
                        Spacer()
                        
                        Picker("Session", selection: $viewModel.selectedSession) {
                            Text("Select a Session").tag(DriveSession?.none)
                            ForEach(sessions) { session in
                                Text(session.title).tag(DriveSession?.some(session))
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(DesignSystem.cyan)
                        
                        if let selected = viewModel.selectedSession {
                            Button(action: {
                                viewModel.deleteSession(selected, context: modelContext)
                            }) {
                                Image(systemName: "trash")
                                    .foregroundColor(.red.opacity(0.7))
                            }
                            .padding(.leading, 4)
                        }
                    }
                    .padding()
                    
                    if let session = viewModel.selectedSession {
                        ScrollView {
                            VStack(spacing: 24) {
                                // Score + Distribution
                                HStack(spacing: 16) {
                                    DrivingScoreView(score: viewModel.drivingScore)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 200)
                                    
                                    // Custom Time Distribution Bar
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
                                
                                SpeedChartView(session: session)
                                    .frame(height: 250)
                                    .padding(.horizontal)
                                
                                OverspeedHeatMapView(session: session)
                                    .frame(height: 320)
                                    .cornerRadius(16)
                                    .padding(.horizontal)
                            }
                            .padding(.bottom, 30)
                        }
                    } else {
                        Spacer()
                        VStack(spacing: 16) {
                            Image(systemName: "car.circle.fill")
                                .font(.system(size: 60))
                                .foregroundColor(DesignSystem.bgCard)
                            Text("No drives recorded yet.")
                                .font(.headline)
                                .foregroundColor(.gray)
                        }
                        Spacer()
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if let first = sessions.first {
                viewModel.selectSession(first)
            }
        }
    }
}
