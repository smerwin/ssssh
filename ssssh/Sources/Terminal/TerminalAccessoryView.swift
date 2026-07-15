import SwiftTerm
import UIKit

/// `SwiftTerm.TerminalAccessory`'s own Tab button (`TerminalAccessory.tab(_:)`) always
/// sends a plain byte `0x09` -- there's no Shift modifier concept anywhere in that class
/// (only `controlModifier`), so Shift+Tab is unreachable from the on-screen keyboard no
/// matter what. `TerminalAccessory` isn't `open` and its button-building internals aren't
/// visible outside SwiftTerm's module, so it can't be subclassed or extended -- this wraps
/// the stock accessory unmodified, narrows it slightly, and docks a single Shift+Tab
/// button at the trailing edge of the same row. `TerminalAccessory` re-lays out its own
/// buttons to whatever width it's given (see its `bounds` didSet), so shrinking it costs a
/// few points off each existing button rather than clipping anything. The button sends
/// bytes by hand using the same legacy-vs-kitty-protocol branching `TerminalView`'s own
/// hardware-key handling uses, so it stays correct whether or not the remote app has
/// requested the kitty keyboard protocol (Claude Code's CLI does, to disambiguate
/// Shift+Tab from a plain Tab).
final class TerminalAccessoryView: UIInputView {
    private weak var terminalView: SwiftTerm.TerminalView?

    init(terminalView: SwiftTerm.TerminalView) {
        let isPhone = UIDevice.current.userInterfaceIdiom == .phone
        let barHeight: CGFloat = isPhone ? 36 : 48
        let width = UIScreen.main.bounds.width

        super.init(frame: CGRect(x: 0, y: 0, width: width, height: barHeight), inputViewStyle: .keyboard)
        self.terminalView = terminalView
        allowsSelfSizing = true

        let builtIn = TerminalAccessory(frame: CGRect(x: 0, y: 0, width: width, height: barHeight),
                                        inputViewStyle: .keyboard, container: terminalView)
        builtIn.translatesAutoresizingMaskIntoConstraints = false
        addSubview(builtIn)

        let shiftTabButton = UIButton(type: .system)
        shiftTabButton.setTitle("⇧⇥", for: .normal)
        shiftTabButton.accessibilityLabel = "Shift Tab"
        shiftTabButton.backgroundColor = .secondarySystemBackground
        shiftTabButton.layer.cornerRadius = 6
        shiftTabButton.contentEdgeInsets = UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        shiftTabButton.addTarget(self, action: #selector(sendShiftTab), for: .touchUpInside)
        shiftTabButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(shiftTabButton)

        NSLayoutConstraint.activate([
            builtIn.topAnchor.constraint(equalTo: topAnchor),
            builtIn.bottomAnchor.constraint(equalTo: bottomAnchor),
            builtIn.leadingAnchor.constraint(equalTo: leadingAnchor),
            builtIn.trailingAnchor.constraint(equalTo: shiftTabButton.leadingAnchor, constant: -6),

            shiftTabButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            shiftTabButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func sendShiftTab() {
        guard let terminalView else { return }
        let flags = terminalView.getTerminal().keyboardEnhancementFlags
        if flags.contains(.disambiguate) || flags.contains(.reportAllKeys) {
            terminalView.send(Array("\u{1b}[9;2u".utf8))
        } else {
            terminalView.send(EscapeSequences.cmdBackTab)
        }
    }
}
