import SwiftUI

public struct TutorialView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    @State private var currentTab = 0
    @State private var showSwipeHint = false
    @State private var skipButtonPulse = false

    public var isReplaying: Bool = false

    public init(isReplaying: Bool = false) {
        self.isReplaying = isReplaying
    }

    private let pages = [
        TutorialPage(title: "Welcome", description: "Speedio is built by Srihan Yeleswarapu.", iconName: "person.circle.fill"),
        TutorialPage(title: "Support", description: "Report issues via the 'Report Issue' button in Settings to reach us at speedsenseapp@gmail.com.", iconName: "exclamationmark.bubble.fill"),
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
                            Spacer()
                                .frame(height: 50)
                                .padding(.bottom, 60)
                        }
                    }
                    .tag(index)
                }
            }
            .tabViewStyle(PageTabViewStyle(indexDisplayMode: .always))

            // ── Swipe-right hint ──────────────────────────────
            if currentTab < pages.count - 1 {
                VStack(spacing: 6) {
                    Text("Swipe right to continue")
                        .font(.caption.weight(.medium))
                        .foregroundColor(DesignSystem.cyan.opacity(0.65))

                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(DesignSystem.cyan.opacity(0.5))
                        .offset(x: showSwipeHint ? 6 : -2)
                }
                .opacity(showSwipeHint ? 1 : 0)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, 80)
            }

            // ── Skip / Close button with subtle pulse ─────────
            Button(action: finishTutorial) {
                Text(isReplaying ? "Close" : "Skip")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(DesignSystem.cyan.opacity(0.15))
                    )
                    .overlay(
                        Capsule()
                            .stroke(DesignSystem.cyan.opacity(skipButtonPulse ? 0.5 : 0.25), lineWidth: 1)
                    )
            }
            .scaleEffect(skipButtonPulse ? 1.05 : 1.0)
            .padding(.top, 12)
            .padding(.leading, 14)
        }
        .onAppear {
            // Animate swipe hint after a brief delay
            withAnimation(.interpolatingSpring(stiffness: 100, damping: 8).delay(0.8)) {
                showSwipeHint = true
            }

            // Start the skip-button pulse loop
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true).delay(1.5)) {
                skipButtonPulse = true
            }
        }
        .onChange(of: currentTab) { _, _ in
            // Reset and re-animate swipe hint on each page turn
            showSwipeHint = false
            withAnimation(.interpolatingSpring(stiffness: 100, damping: 8).delay(0.3)) {
                showSwipeHint = true
            }
        }
    }

    private func finishTutorial() {
        if isReplaying {
            dismiss()
        } else {
            appState.onboardingStep = appState.onboardingStep.nextCase
        }
    }
}

private struct TutorialPage {
    let title: String
    let description: String
    let iconName: String
}