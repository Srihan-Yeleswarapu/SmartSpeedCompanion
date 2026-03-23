import SwiftUI

public struct StateSelectionView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedState = "Arizona"
    @State private var showError = false
    
    private let states = [
        "Alabama", "Alaska", "Arizona", "Arkansas", "California", "Colorado", "Connecticut", "Delaware", "Florida", "Georgia", 
        "Hawaii", "Idaho", "Illinois", "Indiana", "Iowa", "Kansas", "Kentucky", "Louisiana", "Maine", "Maryland", 
        "Massachusetts", "Michigan", "Minnesota", "Mississippi", "Missouri", "Montana", "Nebraska", "Nevada", "New Hampshire", "New Jersey", 
        "New Mexico", "New York", "North Carolina", "North Dakota", "Ohio", "Oklahoma", "Oregon", "Pennsylvania", "Rhode Island", "South Carolina", 
        "South Dakota", "Tennessee", "Texas", "Utah", "Vermont", "Virginia", "Washington", "West Virginia", "Wisconsin", "Wyoming"
    ]
    
    public init() {}
    
    public var body: some View {
        ZStack {
            DesignSystem.bgDeep.ignoresSafeArea()
            
            VStack(spacing: 30) {
                Spacer()
                
                VStack(spacing: 12) {
                    Text("WHERE ARE YOU LOCATED?")
                        .font(.system(size: 24, weight: .black, design: .rounded))
                        .foregroundColor(.white)
                    
                    Text("Select your primary driving state.")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                }
                
                // Scrolling Dial (Wheel Picker)
                Picker("State", selection: $selectedState) {
                    ForEach(states, id: \.self) { state in
                        Text(state)
                            .foregroundColor(.white)
                            .font(.headline)
                    }
                }
                .pickerStyle(.wheel)
                .frame(height: 200)
                .background(DesignSystem.bgPanel.opacity(0.5))
                .cornerRadius(16)
                .padding(.horizontal, 40)
                
                if showError {
                    VStack(spacing: 12) {
                        Text("I deeply apologize for the inconvenience, but Speedio is only available in Arizona at this moment.")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(DesignSystem.alertRed)
                            .multilineTextAlignment(.center)
                        
                        Text("Send us an email at speedsenseapp@gmail.com and send a request and we will do our best to add your state.")
                            .font(.system(size: 13))
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                        
                        Button(action: {
                            let email = "speedsenseapp@gmail.com"
                            if let url = URL(string: "mailto:\(email)") {
                                UIApplication.shared.open(url)
                            }
                        }) {
                            Label("Request Support", systemImage: "envelope.fill")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(DesignSystem.cyan)
                        }
                    }
                    .padding(.horizontal, 40)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                
                Spacer()
                
                Button(action: handleProceed) {
                    Text("CONTINUE")
                        .font(.system(size: 16, weight: .black))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(DesignSystem.cyan)
                        .cornerRadius(12)
                        .shadow(color: DesignSystem.cyan.opacity(0.4), radius: 10)
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 60)
            }
        }
    }
    
    private func handleProceed() {
        if selectedState == "Arizona" {
            withAnimation {
                appState.userState = "Arizona"
                appState.hasSelectedState = true
            }
        } else {
            withAnimation {
                showError = true
            }
        }
    }
}
