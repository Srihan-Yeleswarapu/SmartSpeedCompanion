// Path: Views/Analytics/SummaryStatsView.swift
import SwiftUI

public struct SummaryStatsView: View {
    @ObservedObject var viewModel: AnalyticsViewModel
    @Environment(\.horizontalSizeClass) var sizeClass
    
    public var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: sizeClass == .regular ? 4 : 2)
        
        LazyVGrid(columns: columns, spacing: 12) {
            StatChip(title: "DRIVE TIME", value: viewModel.formattedDuration, color: .white)
            StatChip(title: "% WITHIN LIMIT", value: viewModel.formattedPercentSafe, color: DesignSystem.neonGreen)
            StatChip(title: "MAX OVERSPEED", value: viewModel.longestOverstreak, color: DesignSystem.alertRed)
            StatChip(title: "AVG OVER LIMIT", value: "+\(viewModel.avgSpeedOverLimit)", color: DesignSystem.amber)
        }
    }
}

fileprivate struct StatChip: View {
    let title: String
    let value: String
    let color: Color
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(.gray)
                .lineLimit(1)
            
            Text(value)
                .font(.system(size: 22, weight: .black, design: .rounded))
                .foregroundColor(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(DesignSystem.bgCard)
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(red: 0, green: 212/255, blue: 255/255, opacity: 0.12), lineWidth: 1))
    }
}
