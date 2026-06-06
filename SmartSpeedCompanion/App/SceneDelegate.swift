import UIKit
import SwiftUI
import SwiftData

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    
    // Regular iOS App Scene
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = (scene as? UIWindowScene) else { return }
        
        let window = UIWindow(windowScene: windowScene)
        
        // Use the shared ModelContainer from AppDelegate - it's already initialized
        // before this scene connects, ensuring CarPlay and the app share the same context
        let rootView = AppRootView()
            .environmentObject(AppDelegate.sharedAppState)
            .environmentObject(AppDelegate.sharedDriveViewModel)
            .modelContainer(AppDelegate.sharedModelContainer)
            .preferredColorScheme(.dark)
        window.rootViewController = UIHostingController(rootView: rootView)
        self.window = window
        window.makeKeyAndVisible()
    }
}