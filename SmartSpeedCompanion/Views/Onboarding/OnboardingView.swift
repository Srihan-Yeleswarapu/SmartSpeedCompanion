import SwiftUI

public struct OnboardingView: View {
    @EnvironmentObject var appState: AppState
    @State private var currentStep = 0
    
    public init() {}
    
    private let questions = [
        Question(title: "How did you hear about SpeedSense?", options: ["Friend", "Social media", "App Store", "Internet search", "Other"]),
        Question(title: "What interests you most about SpeedSense?", options: ["Avoiding speeding tickets", "Driving more safely", "Tracking my driving habits", "Curiosity"]),
        Question(title: "What type of driver are you?", options: ["Daily commuter", "Student driver", "Frequent road trip driver", "Delivery / work driver"]),
        Question(title: "Do you want to get a speeding ticket?", options: ["No"]),
        Question(title: "Do you want to drive out of control and crash?", options: ["No"]),
        Question(title: "Do you want to drive safely?", options: ["Yes"]),
        Question(title: "Are you ready for SpeedSense to improve your driving?", options: ["Yes"])
    ]
    
    public var body: some View {
        ZStack {
            DesignSystem.bgDeep.ignoresSafeArea()
            
            VStack {
                // Progress Bar
                ProgressView(value: Double(currentStep + 1), total: Double(questions.count))
                    .progressViewStyle(LinearProgressViewStyle(tint: DesignSystem.cyan))
                    .padding()
                
                Spacer()
                
                Text(questions[currentStep].title)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding()
                    .id("title-\(currentStep)")
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity)))
                
                VStack(spacing: 16) {
                    ForEach(questions[currentStep].options, id: \.self) { option in
                        Button(action: {
                            handleAnswer(option)
                        }) {
                            Text(option)
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(DesignSystem.bgPanel)
                                .foregroundColor(.white)
                                .cornerRadius(12)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(DesignSystem.cyan.opacity(0.5), lineWidth: 1)
                                )
                        }
                    }
                }
                .padding()
                .id("options-\(currentStep)")
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity)))
                
                Spacer()
                Spacer()
            }
        }
    }
    
    private func handleAnswer(_ answer: String) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            if currentStep < questions.count - 1 {
                currentStep += 1
            } else {
                // Finished
                appState.hasCompletedOnboarding = true
            }
        }
    }
}

private struct Question {
    let title: String
    let options: [String]
}
