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
///
/// Wrapping the stock accessory like this instead of assigning it directly as
/// `TerminalView.inputAccessoryView` has one consequence worth calling out:
/// `TerminalView` looks up the active Ctrl state by casting whatever's assigned to
/// `inputAccessoryView` back to `TerminalAccessory` (`terminalAccessory` in
/// `iOSTerminalView.swift`), and that cast always fails here since this wrapper *is* what's
/// assigned, not `builtIn` itself. Left alone, tapping the on-screen Ctrl key would toggle
/// `builtIn.controlModifier` (and its own highlight) with nothing ever reading it, so a
/// following keystroke from the iOS keyboard sends the plain character instead of the
/// control byte. The passthrough tap recognizer and notification observer below exist
/// solely to bridge that gap by mirroring state into `TerminalView.controlModifier`
/// directly, which is the exact fallback that same lookup already reads.
final class TerminalAccessoryView: UIInputView {
    private weak var terminalView: SwiftTerm.TerminalView?
    private weak var builtIn: TerminalAccessory?

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
        self.builtIn = builtIn

        // Passthrough observer: doesn't cancel touches, so builtIn's own buttons (including
        // its Ctrl toggle, which flips `controlModifier` on `.touchDown`) still receive every
        // touch normally. By the time a tap *recognizes* on touch-up, that toggle has already
        // happened, so this just copies the result into `TerminalView.controlModifier`.
        let controlSyncRecognizer = UITapGestureRecognizer(target: self, action: #selector(syncControlModifier))
        controlSyncRecognizer.cancelsTouchesInView = false
        controlSyncRecognizer.delaysTouchesBegan = false
        addGestureRecognizer(controlSyncRecognizer)

        NotificationCenter.default.addObserver(self, selector: #selector(controlModifierWasReset),
                                               name: .terminalViewControlModifierReset, object: terminalView)

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

    @objc private func syncControlModifier() {
        guard let builtIn, let terminalView else { return }
        terminalView.controlModifier = builtIn.controlModifier
    }

    @objc private func controlModifierWasReset() {
        builtIn?.controlModifier = false
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
