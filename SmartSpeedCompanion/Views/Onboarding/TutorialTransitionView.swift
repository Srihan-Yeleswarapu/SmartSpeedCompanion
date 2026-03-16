import SwiftUI

public struct TutorialTransitionView: View {
    @EnvironmentObject var appState: AppState
    @State private var showPrivacy = false
    
    public init() {}
    
    public var body: some View {
        ZStack {
            DesignSystem.bgDeep.ignoresSafeArea()
            
            VStack(spacing: 30) {
                if !showPrivacy {
                    Text("Let's show you how\nSpeedSense works.")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    VStack(spacing: 20) {
                        Image(systemName: "hand.raised.fill")
                            .font(.system(size: 60))
                            .foregroundColor(DesignSystem.cyan)
                        
                        Text("Your Privacy Matters")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                        
                        Text("SpeedSense uses your location to determine your speed and the speed limit of the road you are on.\n\nYour data is never sold or shared.")
                            .font(.headline)
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 30)
                        
                        Button(action: {
                            withAnimation {
                                // Proceed to tutorial flag
                                appState.hasSeenTutorialTransition = true
                            }
                        }) {
                            Text("I Understand")
                                .font(.headline)
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(DesignSystem.cyan)
                                .cornerRadius(12)
                        }
                        .padding(.horizontal, 40)
                        .padding(.top, 20)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation {
                    showPrivacy = true
                }
            }
        }
    }
}
