import Foundation
import AuthenticationServices

public class AuthenticationManager: ObservableObject {
    @Published public var isAuthenticated: Bool = false
    @Published public var currentUserEmail: String?
    
    private let serviceName = "com.speedsense.auth"
    
    public init() {
        checkAuthStatus()
    }
    
    public func checkAuthStatus() {
        if let data = KeychainHelper.standard.read(service: serviceName, account: "userEmail"),
           let email = String(data: data, encoding: .utf8) {
            DispatchQueue.main.async {
                self.isAuthenticated = true
                self.currentUserEmail = email
            }
        } else {
            DispatchQueue.main.async {
                self.isAuthenticated = false
                self.currentUserEmail = nil
            }
        }
    }
    
    public func signUp(username: String, email: String, password: String, completion: @escaping (Result<Void, Error>) -> Void) {
        if username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            completion(.failure(AuthError.invalidUsername))
            return
        }
        
        guard isValidEmail(email) else {
            completion(.failure(AuthError.invalidEmail))
            return
        }
        
        saveUser(email: email, password: password)
        
        DispatchQueue.main.async {
            self.isAuthenticated = true
            self.currentUserEmail = email
            completion(.success(()))
        }
    }
    
    public func signIn(email: String, password: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard isValidEmail(email) else {
            completion(.failure(AuthError.invalidEmail))
            return
        }
        
        if let data = KeychainHelper.standard.read(service: serviceName, account: email),
           let storedPassword = String(data: data, encoding: .utf8) {
            if password == storedPassword {
                saveUserSession(email: email)
                DispatchQueue.main.async {
                    self.isAuthenticated = true
                    self.currentUserEmail = email
                    completion(.success(()))
                }
            } else {
                completion(.failure(AuthError.incorrectPassword))
            }
        } else {
            // Strict checking, must sign up first
            completion(.failure(AuthError.userNotFound))
        }
    }
    
    public func signInWithApple(credential: ASAuthorizationAppleIDCredential) {
        let email = credential.email ?? "appleuser@apple.com"
        saveUserSession(email: email)
        DispatchQueue.main.async {
            self.isAuthenticated = true
            self.currentUserEmail = email
        }
    }
    
    public func signOut() {
        KeychainHelper.standard.delete(service: serviceName, account: "userEmail")
        DispatchQueue.main.async {
            self.isAuthenticated = false
            self.currentUserEmail = nil
        }
    }
    
    private func saveUser(email: String, password: String) {
        let pwdData = Data(password.utf8)
        KeychainHelper.standard.save(pwdData, service: serviceName, account: email)
        saveUserSession(email: email)
    }
    
    private func saveUserSession(email: String) {
        let emailData = Data(email.utf8)
        KeychainHelper.standard.save(emailData, service: serviceName, account: "userEmail")
    }
    
    public func isValidEmail(_ email: String) -> Bool {
        let emailRegex = "[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,64}"
        let emailPredicate = NSPredicate(format:"SELF MATCHES %@", emailRegex)
        return emailPredicate.evaluate(with: email)
    }
}

public enum AuthError: LocalizedError {
    case invalidUsername
    case invalidEmail
    case passwordsDoNotMatch
    case incorrectPassword
    case userNotFound
    
    public var errorDescription: String? {
        switch self {
        case .invalidUsername: return "Username cannot be empty."
        case .invalidEmail: return "Please enter a valid email address."
        case .passwordsDoNotMatch: return "Passwords do not match."
        case .incorrectPassword: return "Incorrect password."
        case .userNotFound: return "User not found. Please sign up."
        }
    }
}
