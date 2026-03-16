import SwiftUI

public struct AuthView: View {
    @State private var isShowingSignUp = false
    
    public init() {}
    
    public var body: some View {
        NavigationStack {
            if isShowingSignUp {
                SignUpView(isShowingSignUp: $isShowingSignUp)
            } else {
                SignInView(isShowingSignUp: $isShowingSignUp)
            }
        }
        .preferredColorScheme(.dark)
    }
}
