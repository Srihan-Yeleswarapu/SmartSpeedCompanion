import Foundation
import AuthenticationServices
import FirebaseAuth
import FirebaseFirestore
import FirebaseCore
import UIKit // For device info if needed

public class AuthenticationManager: ObservableObject {
    public static let shared = AuthenticationManager()
    
    @Published public var isAuthenticated: Bool = false
    @Published public var currentUserEmail: String?
    @Published public var initialAuthChecked: Bool = false
    
    private let serviceName = "com.speedsense.auth"
    private let uidAccount = "userUID"
    
    public init() {
        checkAuthStatus()
    }
    
    private var authHandle: AuthStateDidChangeListenerHandle?
    
    public func checkAuthStatus() {
        // Ensure Firebase is actually configured before calling Auth.auth()
        // This prevents launch crashes if static initialization order is unpredictable.
        guard FirebaseApp.app() != nil else {
            print("AuthenticationManager: Firebase not yet configured. Skipping auth check.")
            initialAuthChecked = true
            return
        }
        
        // Listen to actual Firebase Auth state
        authHandle = Auth.auth().addStateDidChangeListener { [weak self] auth, user in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                if let user = user {
                    self.isAuthenticated = true
                    self.currentUserEmail = user.email
                    self.saveUIDToKeychain(uid: user.uid)
                    self.fetchUserPreferences() // Restore settings
                } else {
                    self.isAuthenticated = false
                    self.currentUserEmail = nil
                    KeychainHelper.standard.delete(service: self.serviceName, account: self.uidAccount)
                }
                
                self.initialAuthChecked = true
            }
        }
    }

    public func signUp(username: String, email: String, password: String) async throws {
        guard FirebaseApp.app() != nil else { throw AuthError.firebaseNotConfigured }

        if username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AuthError.invalidUsername
        }

        guard isValidEmail(email) else { throw AuthError.invalidEmail }

        // Pre-flight: confirm the email isn't already registered. fetchSignInMethods
        // returns an array of provider IDs tied to that email; an empty array means
        // no Firebase Auth user exists for it under any provider.
        let methods = try await Auth.auth().fetchSignInMethods(forEmail: email)
        if !methods.isEmpty {
            throw AuthError.emailAlreadyInUse
        }

        // Create the Auth user. Defense-in-depth: another client could register the
        // same email between our check and our create call; map the canonical
        // "email already in use" error to our typed case so the UI is consistent.
        let authResult: AuthDataResult
        do {
            authResult = try await Auth.auth().createUser(withEmail: email, password: password)
        } catch let nsError as NSError {
            if nsError.domain == AuthErrorDomain,
               nsError.code == AuthErrorCode.emailAlreadyInUse.rawValue {
                throw AuthError.emailAlreadyInUse
            }
            throw nsError
        }

        // Create the Firestore user doc (idempotent merge, non-fatal if it fails).
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.createUserDocument(uid: authResult.user.uid, email: email, username: username) { error in
                if let error = error {
                    print("Error creating user document: \(error)")
                }
                continuation.resume()
            }
        }

        // Surface the new session to the rest of the app on the main thread.
        await MainActor.run {
            self.isAuthenticated = true
            self.currentUserEmail = email
            self.saveUIDToKeychain(uid: authResult.user.uid)
        }
    }
    
    public func signIn(email: String, password: String) async throws {
        guard FirebaseApp.app() != nil else { throw AuthError.firebaseNotConfigured }
        guard isValidEmail(email) else { throw AuthError.invalidEmail }

        // Credential attempt FIRST. With Email Enumeration Protection enabled
        // in the Firebase Console, the distinction between "email not
        // registered" and "wrong password" is intentionally collapsed by
        // Firebase — both come back as `invalidCredential`. Running the
        // credential attempt up front means a wrong password never gets
        // misreported as "no account found" when EEP is on.
        //
        // We only consult `fetchSignInMethods` to disambiguate when the
        // credential attempt fails with a credential-class code.
        let authResult: AuthDataResult
        do {
            authResult = try await Auth.auth().signIn(withEmail: email, password: password)
        } catch let nsError as NSError {
            // Three credential-class outcomes are possible:
            //   - `.userNotFound` / `.emailNotFound`: email is not registered. Throw
            //     our typed case directly — we don't need to consult
            //     `fetchSignInMethods` because the answer is already definitive.
            //   - `.wrongPassword`: email exists, password mismatch. Same.
            //   - `.invalidCredential`: returned by Firebase under Email Enumeration
            //     Protection for BOTH unregistered-email AND wrong-password, so the
            //     result is ambiguous — we have to consult `fetchSignInMethods` to
            //     disambiguate. (When EEP is off, Firebase uses `.userNotFound` /
            //     `.wrongPassword` directly and this branch is unreachable.)
            //   - everything else: network, user-disabled, too-many-requests, etc.
            //     Propagate the original error so the UI surfaces the canonical
            //     Firebase message.
            guard let code = AuthErrorCode(rawValue: nsError.code) else { throw nsError }
            switch code {
            case .userNotFound, .emailNotFound:
                throw AuthError.userNotFound
            case .wrongPassword:
                throw AuthError.incorrectPassword
            case .invalidCredential:
                let methods = try await Auth.auth().fetchSignInMethods(forEmail: email)
                if methods.isEmpty {
                    throw AuthError.userNotFound
                }
                throw AuthError.incorrectPassword
            default:
                throw nsError
            }
        }

        await MainActor.run {
            self.isAuthenticated = true
            self.currentUserEmail = authResult.user.email
            self.saveUIDToKeychain(uid: authResult.user.uid)
            self.fetchUserPreferences()  // parity with the auth-state listener
        }
    }
    
    // MARK: - Apple Sign In
    
    public func signInWithApple(idToken: String, nonce: String, fullName: PersonNameComponents?, completion: @escaping (Result<Void, Error>) -> Void) {
        guard FirebaseApp.app() != nil else {
            completion(.failure(AuthError.firebaseNotConfigured))
            return
        }

        let credential = OAuthProvider.appleCredential(
            withIDToken: idToken,
            rawNonce: nonce,
            fullName: fullName
        )
        
        Auth.auth().signIn(with: credential) { [weak self] authResult, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            
            guard let user = authResult?.user else {
                completion(.failure(AuthError.userNotFound))
                return
            }
            
            // If it's a new user, create their document
            // Apple only provides fullName the FIRST time. 
            // Firebase handles some of this mapping, but we'll ensure we have a record.
            let username = [fullName?.givenName, fullName?.familyName]
                .compactMap { $0 }
                .joined(separator: " ")
            
            self?.createUserDocument(uid: user.uid, email: user.email ?? "", username: username.isEmpty ? "Apple User" : username) { _ in
                DispatchQueue.main.async {
                    self?.isAuthenticated = true
                    self?.currentUserEmail = user.email
                    self?.saveUIDToKeychain(uid: user.uid)
                    completion(.success(()))
                }
            }
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
            "created": FieldValue.serverTimestamp(),
            "lastLocation": [
                "lat": 0.0,
                "lon": 0.0,
                "timestamp": FieldValue.serverTimestamp()
            ]
        ]
        
        userRef.setData(userData, merge: true) { error in
            completion(error)
        }
    }
    
    // MARK: - Cloud Data Syncing
    
    /// Syncs a completed drive session to Firestore under the user's account.
    public func syncDriveSession(_ session: DriveSession) {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let db = Firestore.firestore()
        
        let readingsData: [[String: Any]] = session.readings.map { reading in
            return [
                "timestamp": reading.timestamp,
                "lat": reading.latitude,
                "lon": reading.longitude,
                "speed": reading.speed,
                "limit": reading.speedLimit,
                "over": reading.overLimit
            ]
        }
        
        let sessionData: [String: Any] = [
            "id": session.id.uuidString,
            "startTime": session.startTime,
            "endTime": session.endTime ?? Date(),
            "startName": session.startLocationName ?? "Unknown",
            "endName": session.endLocationName ?? "Unknown",
            "score": session.drivingScore,
            "duration": session.durationSeconds,
            "readings": readingsData
        ]
        
        db.collection("users").document(uid).collection("sessions").document(session.id.uuidString).setData(sessionData) { error in
            if let error = error {
                print("Failed to sync session to cloud: \(error.localizedDescription)")
            } else {
                print("Successfully synced session \(session.id) to cloud.")
            }
        }
    }
    
    /// Updates the user's last known location in their profile.
    public func updateLastLocation(latitude: Double, longitude: Double) {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let db = Firestore.firestore()
        
        db.collection("users").document(uid).updateData([
            "lastLocation": [
                "lat": latitude,
                "lon": longitude,
                "timestamp": FieldValue.serverTimestamp()
            ]
        ])
    }
    
    /// Pushes local settings preferences to the cloud.
    public func syncUserPreferences() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let db = Firestore.firestore()
        
        // Collate all @AppStorage keys
        let defaults = UserDefaults.standard
        let preferences: [String: Any] = [
            "userBuffer": defaults.double(forKey: "userBuffer"),
            "audioAlertsEnabled": defaults.bool(forKey: "audioAlertsEnabled"),
            "hapticsEnabled": defaults.bool(forKey: "hapticsEnabled"),
            "voiceNavEnabled": defaults.bool(forKey: "voiceNavEnabled"),
            "speedUnit": defaults.string(forKey: "speedUnit") ?? "mph",
            "avoidHighways": defaults.bool(forKey: "avoidHighways"),
            "measurementSystem": defaults.string(forKey: "measurementSystem") ?? "Imperial"
        ]
        
        db.collection("users").document(uid).updateData([
            "preferences": preferences,
            "updatedAt": FieldValue.serverTimestamp()
        ])
    }
    
    /// Pulls settings preferences from the cloud and applies them locally.
    public func fetchUserPreferences() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let db = Firestore.firestore()
        
        db.collection("users").document(uid).getDocument { (document, error) in
            if let document = document, document.exists, let data = document.data(), let prefs = data["preferences"] as? [String: Any] {
                let defaults = UserDefaults.standard
                
                // Update local storage
                if let buffer = prefs["userBuffer"] as? Double { defaults.set(buffer, forKey: "userBuffer") }
                if let audio = prefs["audioAlertsEnabled"] as? Bool { defaults.set(audio, forKey: "audioAlertsEnabled") }
                if let haptics = prefs["hapticsEnabled"] as? Bool { defaults.set(haptics, forKey: "hapticsEnabled") }
                if let voice = prefs["voiceNavEnabled"] as? Bool { defaults.set(voice, forKey: "voiceNavEnabled") }
                if let unit = prefs["speedUnit"] as? String { defaults.set(unit, forKey: "speedUnit") }
                if let highways = prefs["avoidHighways"] as? Bool { defaults.set(highways, forKey: "avoidHighways") }
                if let system = prefs["measurementSystem"] as? String { defaults.set(system, forKey: "measurementSystem") }
                
                print("User preferences restored from cloud.")
            }
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

public enum AuthError: LocalizedError, Sendable {
    case invalidUsername
    case invalidEmail
    case passwordsDoNotMatch
    case incorrectPassword
    case firebaseNotConfigured
    case userNotFound
    case emailAlreadyInUse

    public var errorDescription: String? {
        switch self {
        case .invalidUsername: return "Username cannot be empty."
        case .invalidEmail: return "Please enter a valid email address."
        case .passwordsDoNotMatch: return "Passwords do not match."
        case .incorrectPassword: return "Incorrect password. Try again."
        case .firebaseNotConfigured: return "Firebase is not configured. Please ensure GoogleService-Info.plist is included in the app bundle."
        case .userNotFound: return "No account found for this email. Sign up first."
        case .emailAlreadyInUse: return "You already have an account. Sign in instead."
        }
    }
}
