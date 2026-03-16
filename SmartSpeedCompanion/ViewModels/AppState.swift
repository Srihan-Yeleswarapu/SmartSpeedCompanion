import SwiftUI
import Combine

public class AppState: ObservableObject {
    @AppStorage("hasCompletedOnboarding") public var hasCompletedOnboarding: Bool = false
    @AppStorage("hasCompletedTutorial") public var hasCompletedTutorial: Bool = false
    @AppStorage("hasSeenTutorialTransition") public var hasSeenTutorialTransition = false
    
    @Published public var authManager = AuthenticationManager()
    
    // Relay changes from authManager to appState so views can react
    private var cancellables = Set<AnyCancellable>()
    
    public init() {
        authManager.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }
}
