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
    @State private var signUpError: AuthError? = nil
    
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
                    Text("Join Speedio to track your habits")
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
                    VStack(spacing: 8) {
                        Text(errorMessage)
                            .foregroundColor(DesignSystem.alertRed)
                            .font(.caption)
                            .multilineTextAlignment(.center)

                        if signUpError == .emailAlreadyInUse {
                            Button(action: {
                                withAnimation {
                                    isShowingSignUp = false
                                    isError = false
                                    signUpError = nil
                                    errorMessage = ""
                                }
                            }) {
                                Text("Go to Sign In")
                                    .font(.caption.bold())
                                    .foregroundColor(DesignSystem.cyan)
                                    .padding(.vertical, 6)
                                    .padding(.horizontal, 12)
                                    .background(DesignSystem.cyan.opacity(0.15))
                                    .cornerRadius(8)
                            }
                        }
                    }
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
            signUpError = nil
            return
        }

        guard password == confirmPassword else {
            errorMessage = "Passwords do not match."
            isError = true
            signUpError = nil
            return
        }

        isSigningUp = true
        isError = false
        signUpError = nil

        // Capture inputs as locals so the Task closure is unambiguous and the
        // body is implicitly main-isolated (so we can mutate @State directly
        // without inner MainActor.run wrappers).
        let authManager = appState.authManager
        let usernameCopy = username
        let emailCopy = email
        let passwordCopy = password
        // No `resetOnboardingFunnel()` call needed here — when
        // `AuthenticationManager.signUp(...)` succeeds, it posts the
        // `.userDidSignUp` notification and `AppState` (via the
        // observer wired in its `init`) resets the funnel automatically.
        Task { @MainActor in
            do {
                try await authManager.signUp(username: usernameCopy, email: emailCopy, password: passwordCopy)
                self.isSigningUp = false
            } catch {
                self.errorMessage = error.localizedDescription
                self.isError = true
                self.signUpError = error as? AuthError
                self.isSigningUp = false
            }
        }
    }
}