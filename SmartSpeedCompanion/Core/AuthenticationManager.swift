import Foundation
import AuthenticationServices
import FirebaseAuth
import FirebaseFirestore
import FirebaseCore
import SwiftData
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
        // `AppState` listens for the `.userDidSignUp` notification and runs
        // its onboarding-funnel reset inline. Posting here (rather than
        // having each call site remember) means any future sign-up path
        // — magic link, SMS OTP, anonymous upgrade, SSO — automatically
        // gets the same behavior without coupling `AuthenticationManager`
        // to `AppState` directly.
        await MainActor.run {
            self.isAuthenticated = true
            self.currentUserEmail = email
            self.saveUIDToKeychain(uid: authResult.user.uid)
            NotificationCenter.default.post(name: .userDidSignUp, object: nil)
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
            //   - `.userNotFound`: email is not registered. Throw our typed
            //     case directly — we don't need to consult `fetchSignInMethods`
            //     because the answer is already definitive. (NB: the Firebase
            //     iOS SDK does not expose a separate `.emailNotFound` case;
            //     signIn failures for unregistered emails surface as
            //     `.userNotFound` directly.)
            //   - `.wrongPassword`: email exists, password mismatch. Same.
            //   - `.invalidCredential`: returned by Firebase under Email
            //     Enumeration Protection for BOTH unregistered-email AND
            //     wrong-password, so the result is ambiguous — we have to
            //     consult `fetchSignInMethods` to disambiguate. (When EEP is
            //     off, Firebase uses `.userNotFound` / `.wrongPassword`
            //     directly and this branch is unreachable.)
            //   - everything else: network, user-disabled, too-many-requests, etc.
            //     Propagate the original error so the UI surfaces the canonical
            //     Firebase message.
            guard let code = AuthErrorCode(rawValue: nsError.code) else { throw nsError }
            switch code {
            case .userNotFound:
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
                    // Same notification contract as `signUp(...)` — see the
                    // comment in that method for why we post here instead
                    // of calling `resetOnboardingFunnel` directly. Posting
                    // from a `DispatchQueue.main.async` block is safe
                    // because NotificationCenter is thread-safe to post
                    // from any thread, and the observer in `AppState.init`
                    // already uses `queue: .main`.
                    NotificationCenter.default.post(name: .userDidSignUp, object: nil)
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
    
    // MARK: - Account Deletion (Apple App Store Guideline 5.1.1(v))
    
    /// Permanently deletes the user's Firebase Auth account, then optionally wipes the
    /// associated Firestore documents and on-device SwiftData sessions.
    ///
    /// Order of operations matters here:
    /// 1. **Firebase Auth delete FIRST** — this is what Apple App Store Guideline
    ///    5.1.1(v) actually requires (the account itself must be destroyed). It is
    ///    also the only step that can throw `requiresRecentLogin`, which we
    ///    propagate up so the caller can show an in-app re-authentication sheet.
    /// 2. **Firestore cleanup SECOND** — performed as best-effort after the Auth
    ///    user is destroyed. Failures here are logged.
    /// 3. **Local SwiftData wipe THIRD** — best-effort. The auth-state listener
    ///    in `checkAuthStatus()` will fire `isAuthenticated = false` automatically
    ///    after step 1, which redirects the root view away from the Settings tab.
    ///
    /// Marked `@MainActor` so calls from SwiftUI `Task { ... }` bodies don't need
    /// extra isolation hops when they synchronously read `isAuthenticated` /
    /// `currentUserEmail` immediately after this returns.
    @MainActor
    public func deleteAccount() async throws {
        guard FirebaseApp.app() != nil else { throw AuthError.firebaseNotConfigured }
        guard let user = Auth.auth().currentUser else { throw AuthError.userNotFound }

        // Snapshot the UID before we destroy the user object, so the post-delete
        // cleanup can still target `users/{uid}` even after `currentUser` is nil.
        let uid = user.uid

        // 1. Firebase Auth delete — may throw `requiresRecentLogin` if the user
        //    hasn't signed in within the last ~1 hour. Map that to our typed case.
        do {
            try await user.delete()
        } catch let nsError as NSError {
            guard let code = AuthErrorCode(rawValue: nsError.code) else { throw nsError }
            switch code {
            case .requiresRecentLogin:
                throw AuthError.requiresRecentLogin
            default:
                throw nsError
            }
        }

        // 2 & 3. Track whether each backend-cleanup attempt succeeded so we can
        // surface `partialDeletion` to the caller when BOTH fail. The Auth account
        // is already gone at this point regardless of outcome (Apple 5.1.1(v) is
        // satisfied either way), so we log and continue on individual failures
        // but report a typed error when neither cleanup path completed.
        var firestoreCleanupOK = true
        do {
            try await deleteFirestoreUserData(uid: uid)
        } catch {
            firestoreCleanupOK = false
            DebugLogger.shared.log("Account delete: Firestore cleanup FAILED for uid \(uid) (account already deleted): \(error.localizedDescription)")
        }

        var localCleanupOK = true
        do {
            try await clearLocalData()
        } catch {
            localCleanupOK = false
            DebugLogger.shared.log("Account delete: Local cleanup FAILED (account already deleted): \(error.localizedDescription)")
        }

        if !firestoreCleanupOK || !localCleanupOK {
            throw AuthError.partialDeletion
        }

        // The auth-state listener in `checkAuthStatus()` is already wired to
        // set `isAuthenticated = false` when the Auth user disappears, so we
        // do NOT need to manually publish that here. Doing so would cause a
        // brief flash of "signed out" before the listener settles.
    }
    
    /// Re-authenticates the current Firebase user with the supplied email/password
    /// credential. Call this to refresh the recent-login window when
    /// `deleteAccount()` throws `AuthError.requiresRecentLogin`.
    ///
    /// After this succeeds, re-invoke `deleteAccount()` — Firebase will accept the
    /// deletion because the user has just been verified.
    public func reauthenticate(email: String, password: String) async throws {
        guard FirebaseApp.app() != nil else { throw AuthError.firebaseNotConfigured }
        guard let user = Auth.auth().currentUser else { throw AuthError.userNotFound }
        guard isValidEmail(email) else { throw AuthError.invalidEmail }
        guard !password.isEmpty else { throw AuthError.incorrectPassword }
        
        let credential = EmailAuthProvider.credential(withEmail: email, password: password)
        do {
            try await user.reauthenticate(with: credential)
        } catch let nsError as NSError {
            // Mirror the disambiguation policy used by `signIn(...)` so the UI
            // gets a typed `AuthError` instead of an opaque `NSError`.
            guard let code = AuthErrorCode(rawValue: nsError.code) else { throw nsError }
            switch code {
            case .userNotFound, .invalidCredential:
                // Surface as `userNotFound` — the Auth user obviously exists
                // (we have `currentUser`), so a Firebase no-account error here
                // indicates the supplied credentials don't belong to anyone.
                throw AuthError.userNotFound
            case .wrongPassword:
                throw AuthError.incorrectPassword
            default:
                throw nsError
            }
        }
    }
    
    /// Convenience: re-authenticate with email/password, then immediately delete
    /// the account. Use after `deleteAccount()` throws `requiresRecentLogin`.
    public func reauthenticateAndDeleteAccount(email: String, password: String) async throws {
        try await reauthenticate(email: email, password: password)
        try await deleteAccount()
    }
    
    /// Deletes the user's Firestore profile doc and all subcollection rows.
    ///
    /// Sessions can number in the hundreds over many drives; each session doc
    /// embeds a `"readings"` array of GPS points, so the parent doc itself
    /// could be hundreds of KB. We batch the subcollection deletes (Firestore
    /// write batches support up to 500 ops per commit) and then delete the
    /// parent `users/{uid}` doc.
    ///
    /// Hard cap of `maxIterations * 500 = 10_000` session deletes — beyond
    /// that we log and stop. Hundreds of drives at 1 Hz readings would
    /// still only produce a few dozen actual session docs; 10k is generous.
    private func deleteFirestoreUserData(uid: String) async throws {
        let db = Firestore.firestore()
        let sessionsRef = db.collection("users").document(uid).collection("sessions")

        let maxIterations = 20
        var iterations = 0
        while true {
            iterations += 1
            if iterations > maxIterations {
                DebugLogger.shared.log("Account delete: Firestore session cleanup hit cap (\(maxIterations) iterations). Stopping.")
                break
            }
            let snapshot = try await sessionsRef.limit(to: 500).getDocuments()
            if snapshot.documents.isEmpty { break }

            let batch = db.batch()
            for doc in snapshot.documents {
                batch.deleteDocument(doc.reference)
            }
            try await batch.commit()

            // If we got back fewer than the limit we requested, we're done.
            if snapshot.documents.count < 500 { break }
        }

        // Finally, delete the parent profile doc.
        try await db.collection("users").document(uid).delete()
    }

    /// Best-effort local device wipe:
    /// 1. Removes the per-user UserDefaults entries the app owns
    ///    (current search history). Note: we intentionally do NOT nuke
    ///    `userBuffer` / `audioAlertsEnabled` / etc. — those are app-wide
    ///    preferences keyed to the install, not the user, and wiping them
    ///    would force the next person to re-tune every preference.
    /// 2. Deletes every recorded `DriveSession` row from the shared
    ///    SwiftData container. Cascade-delete on the `@Relationship`
    ///    (`deleteRule: .cascade`) automatically removes the related
    ///    `SpeedReading` rows, so we don't need to fetch them separately.
    ///
    /// Note: the iOS Keychain entry that caches the Firebase UID is wiped
    /// automatically by the auth-state listener in `checkAuthStatus()` when
    /// `currentUser` becomes nil — no manual `KeychainHelper.delete` here.
    @MainActor
    private func clearLocalData() async throws {
        // 1. UserDefaults — remove per-user history items the next user
        //    should not see. We deliberately leave `@AppStorage` keys alone
        //    because those represent device-level, not user-level, prefs.
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "recentSearches")

        // 2. SwiftData — fetch every recorded DriveSession and delete it.
        //    The `@Relationship(deleteRule: .cascade)` on `DriveSession.readings`
        //    cascades the delete to `SpeedReading` rows automatically.
        let context = AppDelegate.sharedModelContainer.mainContext
        let descriptor = FetchDescriptor<DriveSession>()
        let sessions = try context.fetch(descriptor)
        for session in sessions {
            context.delete(session)
        }
        if context.hasChanges {
            try context.save()
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
    /// Firebase Auth rejected `currentUser.delete()` because the user hasn't
    /// signed in within the last ~1 hour. The caller MUST surface an in-app
    /// re-authentication flow (not a mailto/customer-support bounce) to satisfy
    /// Apple App Store Guideline 5.1.1(v).
    case requiresRecentLogin
    /// Account deletion completed for the Firebase Auth record, but the
    /// trailing Firestore / local SwiftData cleanup could not finish. The
    /// account itself IS destroyed — only residual metadata or local rows
    /// may remain. App reviewers usually accept this, but the user is shown
    /// a clear message so they know to manually prune if it persists.
    case partialDeletion

    public var errorDescription: String? {
        switch self {
        case .invalidUsername: return "Username cannot be empty."
        case .invalidEmail: return "Please enter a valid email address."
        case .passwordsDoNotMatch: return "Passwords do not match."
        case .incorrectPassword: return "Incorrect password. Try again."
        case .firebaseNotConfigured: return "Firebase is not configured. Please ensure GoogleService-Info.plist is included in the app bundle."
        case .userNotFound: return "No account found for this email. Sign up first."
        case .emailAlreadyInUse: return "You already have an account. Sign in instead."
        case .requiresRecentLogin: return "For security, please sign in again to confirm account deletion."
        case .partialDeletion: return "Your account was deleted, but some background cleanup did not finish. The data cannot be accessed without your login — manually prune any leftover history from the app or contact support."
        }
    }
}
