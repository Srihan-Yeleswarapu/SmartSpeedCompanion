import SwiftUI

public struct AnimatedRingView: View {
    let score: Int
    @State private var animatedScore: Double = 0
    
    public init(score: Int) {
        self.score = score
    }
    
    var color: Color {
        if score >= 80 { return DesignSystem.neonGreen }
        if score >= 60 { return DesignSystem.amber     }
        return DesignSystem.alertRed
    }
    
    var label: String {
        if score >= 80 { return "EXCELLENT" }
        if score >= 60 { return "FAIR" }
        return "NEEDS WORK"
    }
    
    public var body: some View {
        VStack {
            ZStack {
                Circle()
                    .stroke(DesignSystem.bgCard, lineWidth: 15)
                
                Circle()
                    .trim(from: 0.0, to: CGFloat(animatedScore / 100.0))
                    .stroke(color, style: StrokeStyle(lineWidth: 15, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: color.opacity(0.5), radius: 10, x: 0, y: 0)
                
                VStack {
                    Text("\(Int(animatedScore))")
                        .font(DesignSystem.displayFont)
                        .foregroundColor(.white)
                    Text(label)
                        .font(DesignSystem.labelFont)
                        .foregroundColor(.gray)
                }
            }
            .padding()
        }
        .onAppear {
            withAnimation(.spring(duration: 1.2)) {
                animatedScore = Double(score)
            }
        }
    }
}
