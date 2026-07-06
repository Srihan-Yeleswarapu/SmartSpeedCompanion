import SwiftUIpublic struct AuthView: View {
    @State private var isShowingSignUp: Bool

    /// - Parameter defaultToSignUp: When `true`, the view opens on the Sign Up tab.
    ///   Used by the first-run onboarding funnel so brand-new users land on Sign Up
    ///   rather than Sign In. Returning users (who have previously authenticated)
    ///   still land on Sign In.
    public init(defaultToSignUp: Bool = false) {
        self._isShowingSignUp = State(initialValue: defaultToSignUp)
    }

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