import SwiftUI

public class AppState: ObservableObject {
    @AppStorage("hasCompletedOnboarding") public var hasCompletedOnboarding: Bool = false
    @AppStorage("hasCompletedTutorial") public var hasCompletedTutorial: Bool = false
    @AppStorage("hasSeenTutorialTransition") public var hasSeenTutorialTransition = false
    
    @Published public var authManager = AuthenticationManager()
    
    public init() {}
}
