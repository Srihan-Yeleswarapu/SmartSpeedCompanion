import Foundation
import AuthenticationServices
import FirebaseAuth
import FirebaseFirestore
import UIKit // For device info if needed

public class AuthenticationManager: ObservableObject {
    @Published public var isAuthenticated: Bool = false
    @Published public var currentUserEmail: String?
    @Published public var initialAuthChecked: Bool = false
    
    private let serviceName = "com.speedsense.auth"
    private let uidAccount = "userUID"
    
    public init() {
        checkAuthStatus()
    }
    
    public func checkAuthStatus() {
        // Fast local check via Keychain for perceived performance
        if let uidData = KeychainHelper.standard.read(service: serviceName, account: uidAccount),
           let uid = String(data: uidData, encoding: .utf8), !uid.isEmpty {
            self.isAuthenticated = true
            // Real check in background
        }
        
        // Listen to actual Firebase Auth state
        Auth.auth().addStateDidChangeListener { [weak self] auth, user in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                if let user = user {
                    self.isAuthenticated = true
                    self.currentUserEmail = user.email
                    self.saveUIDToKeychain(uid: user.uid)
                } else {
                    self.isAuthenticated = false
                    self.currentUserEmail = nil
                    KeychainHelper.standard.delete(service: self.serviceName, account: self.uidAccount)
                }
                
                self.initialAuthChecked = true
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
        
        // Firebase Auth Create User
        Auth.auth().createUser(withEmail: email, password: password) { [weak self] authResult, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            
            guard let user = authResult?.user else {
                completion(.failure(AuthError.userNotFound))
                return
            }
            
            // Create Firestore Record
            self?.createUserDocument(uid: user.uid, email: email, username: username) { error in
                if let error = error {
                    // It's a non-fatal error if Firestore fails, but we should log it
                    print("Error creating user document: \(error)")
                }
                
                DispatchQueue.main.async {
                    self?.isAuthenticated = true
                    self?.currentUserEmail = email
                    self?.saveUIDToKeychain(uid: user.uid)
                    completion(.success(()))
                }
            }
        }
    }
    
    public func signIn(email: String, password: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard isValidEmail(email) else {
            completion(.failure(AuthError.invalidEmail))
            return
        }
        
        Auth.auth().signIn(withEmail: email, password: password) { [weak self] authResult, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            
            guard let user = authResult?.user else {
                completion(.failure(AuthError.userNotFound))
                return
            }
            
            DispatchQueue.main.async {
                self?.isAuthenticated = true
                self?.currentUserEmail = user.email
                self?.saveUIDToKeychain(uid: user.uid)
                completion(.success(()))
            }
        }
    }
    
    // Note: To fully integrate Apple Sign In with Firebase, use OAuthProvider. 
    // This is kept here to not break the UI flow, but creates an anonymous-like session locally.
    public func signInWithApple(credential: ASAuthorizationAppleIDCredential) {
        let email = credential.email ?? "appleuser@apple.com"
        let mockUid = credential.user // Apple's unique user identifier
        
        saveUIDToKeychain(uid: mockUid)
        
        DispatchQueue.main.async {
            self.isAuthenticated = true
            self.currentUserEmail = email
        }
    }
    
    public func signOut() {
        do {
            try Auth.auth().signOut()
            KeychainHelper.standard.delete(service: serviceName, account: uidAccount)
            
            DispatchQueue.main.async {
                self.isAuthenticated = false
                self.currentUserEmail = nil
            }
        } catch {
            print("Error signing out: \(error)")
        }
    }
    
    // MARK: - Firestore Helpers
    
    private func createUserDocument(uid: String, email: String, username: String, completion: @escaping (Error?) -> Void) {
        let db = Firestore.firestore()
        let userRef = db.collection("users").document(uid)
        
        let userData: [String: Any] = [
            "email": email,
            "username": username,
            "subscription": "free",
            "created": FieldValue.serverTimestamp()
        ]
        
        userRef.setData(userData) { error in
            completion(error)
        }
    }
    
    // MARK: - Local Keychain Auth
    
    private func saveUIDToKeychain(uid: String) {
        let uidData = Data(uid.utf8)
        KeychainHelper.standard.save(uidData, service: serviceName, account: uidAccount)
    }
    
    // MARK: - Validation
    
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
