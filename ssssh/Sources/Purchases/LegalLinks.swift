import Foundation

/// Apple requires the Terms of Use (EULA) and Privacy Policy to be linked
/// near the purchase button for auto-renewable subscriptions (App Store
/// Review Guideline 3.1.2). ssssh has no custom terms, so it uses Apple's
/// standard EULA.
enum LegalLinks {
    static let termsOfUse = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    static let privacyPolicy = URL(string: "https://github.com/smerwin/ssssh/blob/main/PRIVACY.md")!
}
