import CarPlay
import UIKit

// Added as requested for arbitrary alerts outside SceneDelegate.
class CarPlayAlertController {
    static func createSimpleAlert(title: String, dismissHandler: @escaping () -> Void) -> CPAlertTemplate {
        let action = CPAlertAction(title: "OK", style: .default) { _ in
            dismissHandler()
        }
        return CPAlertTemplate(titleVariants: [title], actions: [action])
    }
}
