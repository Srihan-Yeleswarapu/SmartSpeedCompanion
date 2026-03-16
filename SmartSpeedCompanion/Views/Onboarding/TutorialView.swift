import SwiftUI

public struct TutorialView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    @State private var currentTab = 0
    
    public var isReplaying: Bool = false
    
    public init(isReplaying: Bool = false) {
        self.isReplaying = isReplaying
    }
    
    private let pages = [
        TutorialPage(title: "Current Speed", description: "Shows your real-time driving speed.", iconName: "speedometer"),
        TutorialPage(title: "Speed Limit", description: "Displays the current road speed limit.", iconName: "signpost.right"),
        TutorialPage(title: "Search Bar", description: "Allows searching for locations.", iconName: "magnifyingglass"),
        TutorialPage(title: "Start Drive", description: "Begins a driving session.", iconName: "play.fill"),
        TutorialPage(title: "Sessions History", description: "Shows previous driving sessions.", iconName: "clock.arrow.circlepath"),
        TutorialPage(title: "Analytics", description: "Displays driving insights and statistics.", iconName: "chart.bar.xaxis")
    ]
    
    public var body: some View {
        ZStack(alignment: .topLeading) {
            DesignSystem.bgDeep.ignoresSafeArea()
            
            TabView(selection: $currentTab) {
                ForEach(0..<pages.count, id: \.self) { index in
                    VStack(spacing: 20) {
                        Spacer()
                        
                        Image(systemName: pages[index].iconName)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 100, height: 100)
                            .foregroundColor(DesignSystem.cyan)
                            .padding(.bottom, 30)
                        
                        Text(pages[index].title)
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                        
                        Text(pages[index].description)
                            .font(.headline)
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                        
                        Spacer()
                        
                        if index == pages.count - 1 {
                            Button(action: finishTutorial) {
                                Text(isReplaying ? "Done" : "Get Started")
                                    .font(.headline)
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(DesignSystem.cyan)
                                    .cornerRadius(12)
                            }
                            .padding(.horizontal, 40)
                            .padding(.bottom, 60)
                        } else {
                            // Dummy spacer block to align everything properly
                            Spacer()
                                .frame(height: 50)
                                .padding(.bottom, 60)
                        }
                    }
                    .tag(index)
                }
            }
            .tabViewStyle(PageTabViewStyle(indexDisplayMode: .always))
            
            Button(action: finishTutorial) {
                Text(isReplaying ? "Close" : "Skip")
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding()
            }
            .padding(.top, 10)
            .padding(.leading, 10)
        }
    }
    
    private func finishTutorial() {
        if isReplaying {
            dismiss()
        } else {
            appState.hasCompletedTutorial = true
        }
    }
}

private struct TutorialPage {
    let title: String
    let description: String
    let iconName: String
}