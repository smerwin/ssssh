import SwiftUI

extension View {
    /// Disables autocapitalization on iOS (a no-op elsewhere, where there's
    /// no on-screen keyboard to autocapitalize) -- for text fields expecting
    /// a literal identifier like a hostname, username, or key label.
    @ViewBuilder
    func noAutoCapitalization() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never)
        #else
        self
        #endif
    }
}
