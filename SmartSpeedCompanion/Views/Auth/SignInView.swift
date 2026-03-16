import SwiftUI
import AuthenticationServices

public struct SignInView: View {
    @EnvironmentObject var appState: AppState
    @Binding var isShowingSignUp: Bool
    
    @State private var email = ""
    @State private var password = ""
    @State private var errorMessage = ""
    @State private var isError = false
    @State private var isSigningIn = false
    
    public var body: some View {
        ZStack {
            DesignSystem.bgDeep.ignoresSafeArea()
            
            VStack(spacing: 30) {
                Spacer()
                
                VStack(spacing: 8) {
                    Image(systemName: "speedometer")
                        .font(.system(size: 60))
                        .foregroundColor(DesignSystem.cyan)
                    Text("SpeedSense")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text("Sign in to continue")
                        .foregroundColor(.gray)
                }
                
                VStack(spacing: 16) {
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
                }
                .padding(.horizontal)
                
                if isError {
                    Text(errorMessage)
                        .foregroundColor(DesignSystem.alertRed)
                        .font(.caption)
                }
                
                Button(action: handleSignIn) {
                    HStack {
                        if isSigningIn {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        } else {
                            Text("Sign In")
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
                .disabled(isSigningIn)
                
                HStack {
                    VStack { Divider().background(Color.gray) }
                    Text("OR")
                        .foregroundColor(.gray)
                        .font(.caption)
                    VStack { Divider().background(Color.gray) }
                }
                .padding(.horizontal)
                
                SignInWithAppleButton { request in
                    request.requestedScopes = [.email, .fullName]
                } onCompletion: { result in
                    switch result {
                    case .success(let authorization):
                        if let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential {
                            appState.authManager.signInWithApple(credential: appleIDCredential)
                        }
                    case .failure(let error):
                        self.errorMessage = error.localizedDescription
                        self.isError = true
                    }
                }
                .signInWithAppleButtonStyle(.white)
                .frame(height: 50)
                .padding(.horizontal)
                
                Spacer()
                
                Button(action: {
                    withAnimation {
                        isShowingSignUp = true
                    }
                }) {
                    HStack {
                        Text("Don't have an account?")
                            .foregroundColor(.gray)
                        Text("Sign Up")
                            .foregroundColor(DesignSystem.cyan)
                            .fontWeight(.bold)
                    }
                }
            }
            .padding()
        }
    }
    
    private func handleSignIn() {
        guard !email.isEmpty, !password.isEmpty else {
            errorMessage = "Please enter email and password."
            isError = true
            return
        }
        
        isSigningIn = true
        isError = false
        
        appState.authManager.signIn(email: email, password: password) { result in
            self.isSigningIn = false
            switch result {
            case .success:
                break // AppState view logic will navigate
            case .failure(let error):
                self.errorMessage = error.localizedDescription
                self.isError = true
            }
        }
    }
}
