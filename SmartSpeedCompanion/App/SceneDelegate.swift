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
        
        // Use SwiftData container
        let container = try? ModelContainer(for: DriveSession.self, SpeedReading.self)
        
        let rootView = DriveRootView()
            .environmentObject(AppDelegate.sharedDriveViewModel)
            .modelContainer(container!)
            .preferredColorScheme(.dark)
        
        window.rootViewController = UIHostingController(rootView: rootView)
        self.window = window
        window.makeKeyAndVisible()
    }
}
