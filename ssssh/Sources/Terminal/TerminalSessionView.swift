import SwiftUI
import SwiftTerm

/// UIKit bridge for SwiftTerm's `TerminalView`. Wiring the PTY byte stream
/// from `SSHClient` into this view (via `TerminalViewDelegate`) is milestone
/// 2 work ("Connect + terminal") — this scaffold only proves the view mounts.
struct TerminalSessionView: View {
    let host: SSHHost
    @State private var theme: TerminalTheme = .crtGreen

    var body: some View {
        TerminalHostView(theme: theme)
            .navigationTitle(host.nickname)
            .background(theme.background)
            .ignoresSafeArea(edges: .bottom)
    }
}

private struct TerminalHostView: UIViewRepresentable {
    let theme: TerminalTheme

    func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        let view = SwiftTerm.TerminalView(frame: .zero)
        view.backgroundColor = UIColor(theme.background)
        return view
    }

    func updateUIView(_ uiView: SwiftTerm.TerminalView, context: Context) {
        // TODO: apply theme colors and feed PTY output once SSHClient exists.
    }
}
