import SwiftUI

public struct SignUpView: View {
    @EnvironmentObject var appState: AppState
    @Binding var isShowingSignUp: Bool
    
    @State private var username = ""
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var errorMessage = ""
    @State private var isError = false
    @State private var isSigningUp = false
    
    public var body: some View {
        ZStack {
            DesignSystem.bgDeep.ignoresSafeArea()
            
            VStack(spacing: 30) {
                Spacer()
                
                VStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.system(size: 60))
                        .foregroundColor(DesignSystem.cyan)
                    Text("Create Account")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text("Join SpeedSense to track your habits")
                        .foregroundColor(.gray)
                }
                
                VStack(spacing: 16) {
                    TextField("Username", text: $username)
                        .autocapitalization(.none)
                        .padding()
                        .background(DesignSystem.bgPanel)
                        .cornerRadius(12)
                        .foregroundColor(.white)
                    
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                        .padding()
                        .background(DesignSystem.bgPanel)
                        .cornerRadius(12)
                        .foregroundColor(.white)
                    
                    SecureField("Password", text: $password)
                        .padding()
                        .background(DesignSystem.bgPanel)
                        .cornerRadius(12)
                        .foregroundColor(.white)
                    
                    SecureField("Confirm Password", text: $confirmPassword)
                        .padding()
                        .background(DesignSystem.bgPanel)
                        .cornerRadius(12)
                        .foregroundColor(.white)
                }
                .padding(.horizontal)
                
                if isError {
                    Text(errorMessage)
                        .foregroundColor(DesignSystem.alertRed)
                        .font(.caption)
                }
                
                Button(action: handleSignUp) {
                    HStack {
                        if isSigningUp {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        } else {
                            Text("Sign Up")
                                .font(.headline)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(DesignSystem.cyan)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                .padding(.horizontal)
                .disabled(isSigningUp)
                
                Spacer()
                
                Button(action: {
                    withAnimation {
                        isShowingSignUp = false
                    }
                }) {
                    HStack {
                        Text("Already have an account?")
                            .foregroundColor(.gray)
                        Text("Sign In")
                            .foregroundColor(DesignSystem.cyan)
                            .fontWeight(.bold)
                    }
                }
            }
            .padding()
        }
    }
    
    private func handleSignUp() {
        guard !username.isEmpty, !email.isEmpty, !password.isEmpty, !confirmPassword.isEmpty else {
            errorMessage = "All fields are required."
            isError = true
            return
        }
        
        guard password == confirmPassword else {
            errorMessage = "Passwords do not match."
            isError = true
            return
        }
        
        isSigningUp = true
        isError = false
        
        appState.authManager.signUp(username: username, email: email, password: password) { result in
            self.isSigningUp = false
            switch result {
            case .success:
                break // State will update automatically
            case .failure(let error):
                self.errorMessage = error.localizedDescription
                self.isError = true
            }
        }
    }
}