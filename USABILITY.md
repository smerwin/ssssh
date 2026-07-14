# ssssh Usability & Accessibility Audit

Scope: static review of every SwiftUI view and its supporting model/store
code under `ssssh/Sources`, plus the relevant parts of the bundled
SwiftTerm dependency (VoiceOver/Dynamic Type integration). No changes were
made to the app as part of this audit — this document is a findings
report only.

Method: read every source file in the app target, cross-referenced
against iOS Human Interface Guidelines and WCAG-style checks (contrast,
Dynamic Type, VoiceOver reachability, motion, confirmation for destructive
actions), and checked what accessibility APIs (if any) the app's own code
calls. Grepping the app's own sources for `accessibility`, `Accessibility`,
`dynamicTypeSize`, and `sizeCategory` turned up **zero** matches outside a
single doc comment — every accessibility behavior the app has today comes
from SwiftUI/UIKit defaults or from SwiftTerm, not from explicit code in
this repo. That absence shapes most of the findings below.

Severity key: **Critical** (data loss, or a core flow is unusable for a
group of users) · **Major** (real friction or a confusing/misleading
state, but there's a workaround) · **Minor** (polish, small percentage of
users affected).

---

## Critical

### 1. Deleting a key is instant, irreversible, and has no export/backup path
`KeyListView.swift:29-33` wires key deletion to the List's native
`.onDelete`, which fires a swipe-to-delete with no confirmation alert.
`KeyStore.delete` (`KeyStore.swift:35-39`) immediately removes the private
key material from the Keychain. Private keys are stored
`kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and are explicitly **never
synced to iCloud Keychain** (`Keychain.swift:6-8`), and there is no export
of private key material anywhere in the app (`KeyDetailView` only offers
Copy/Share/QR of the *public* key, `KeyDetailView.swift:32-45`). So: one
swipe, no confirmation, and the key is gone forever with no backup —
including any hosts it was the sole credential for. This is the right
security default (private keys shouldn't leave the device), but it means
the UI is the *only* safety net, and today there is none.
- **Recommendation to consider later**: a confirmation dialog (`role:
  .destructive` alert, not just a swipe button) before deleting a key,
  and/or surfacing "used by N host(s)" in that confirmation the way
  `KeyDetailView` already tracks `deployedHostIDs`.

### 2. Same pattern for hosts and for "Forget Known Host Key"
`HostListView.swift:33-45` and `:46-69` offer host deletion via both swipe
action and context menu with no confirmation, and a destructive "Forget
Known Host Key" context-menu action (`HostListView.swift:57-63`) that
discards the TOFU (trust-on-first-use) fingerprint with no confirmation
either. Losing a host profile is lower-stakes than losing a key (it can be
re-added), but "Forget Known Host Key" is a security-relevant action —
forgetting a host's known fingerprint means the next connection will
silently re-trust whatever key the server presents, re-opening the exact
MITM window TOFU exists to close. It deserves at least the same
confirmation weight as the original trust prompt
(`HostKeyConfirmationView.swift`), not a same-tap-as-"Delete" context menu
entry.

---

## Accessibility (VoiceOver, Dynamic Type, contrast, motion)

### 3. The terminal's text size never responds to the system's Dynamic Type / text-size setting
Every other screen in the app builds its text with semantic styles
(`.headline`, `.subheadline`, `.footnote`, `.caption2`, etc. — see
`HostListView.swift:27-30`, `SessionsListView.swift:25-27`,
`KeyListView.swift:22-25`), which scale automatically with the system
text-size setting. The terminal itself does not: `TerminalHostView`
(`TerminalSessionView.swift:72-91`) never reads
`UITraitCollection.preferredContentSizeCategory` or calls SwiftTerm's
`setFonts(normal:bold:italic:boldItalic:)`, so the terminal always renders
at SwiftTerm's own default font size regardless of the user's iOS text
size setting — including "Larger Accessibility Sizes." Since the terminal
*is* the app's primary content surface, this means the single biggest
accessibility lever a low-vision user has (bumping system text size) does
nothing for the one screen where it matters most. Pinch-to-zoom is not
offered as an alternative either (SwiftTerm's `TerminalView` is a
`UIScrollView` subclass but nothing in `TerminalHostView` configures a
zoom scale).

### 4. The terminal's High Contrast theme is opt-in only — it doesn't follow the system's Increase Contrast setting
`TerminalTheme.swift` defines a `.highContrast` case (white-on-black, no
scanline overlay), but it's a manual picker choice in Settings
(`SettingsView.swift:29-38`), not something that engages automatically
when the user has iOS's own **Settings > Accessibility > Display &
Text Size > Increase Contrast** turned on. A user who has already told iOS
"I need higher contrast everywhere" gets the app's default `crtGreen`
theme (bright green on black, plus a scanline/vignette overlay —
`ScanlineOverlay.swift`) unless they separately discover and change a
second, app-specific setting. The same gap exists for **Reduce
Transparency**: the scanline overlay is tied to the theme
(`TerminalTheme.showsScanlines`, `TerminalTheme.swift:32-34`), not to
`UIAccessibility.isReduceTransparencyEnabled` / the `.accessibilityReduceTransparency`
environment value, which SwiftUI exposes for exactly this purpose.
- Positive note: the vignette/scanline effect is genuinely subtle (fill
  opacities of 0.06 and up to 0.12, `ScanlineOverlay.swift:12,18`) and the
  app has no animations anywhere in its own code (`grep` for `.animation`/
  `withAnimation`/`transition(` across `Sources` returns nothing), so
  Reduce Motion isn't a live concern today.

### 5. The only way to toggle the keyboard is a gesture that VoiceOver intercepts, with no alternate control
`TerminalSessionController` (`TerminalViewStore.swift:29-40`) adds a
single-finger swipe-down/swipe-up `UISwipeGestureRecognizer` pair as the
*only* way to dismiss or re-summon the keyboard
(`handleSwipeDown`/`handleSwipeUp`, `TerminalViewStore.swift:43-49`, wired
in `TerminalSessionView.swift`'s doc comment and CLAUDE.md's own note that
this is deliberately swipe-only, not double-tap, to avoid colliding with
SwiftTerm's built-in word-selection gesture). When VoiceOver is running,
single-finger swipes are reserved system-wide for VoiceOver's own
navigation, and SwiftTerm's `TerminalView` already repurposes vertical
swipes for VoiceOver's line-by-line reading via
`accessibilityScroll(_:)` (confirmed in SwiftTerm's
`iOSTerminalView.swift:1705`). In other words, a VoiceOver user's swipe
up/down on the terminal scrolls terminal content, not the keyboard — so
there is no way for a VoiceOver user to dismiss the keyboard once it's up
(it will keep covering roughly half the terminal) short of navigating away
from the session entirely. There's no toolbar "Done"/keyboard-dismiss
button anywhere in `TerminalSessionView` to fall back on.
- SwiftTerm does otherwise give VoiceOver users a real way to read
  terminal output (it implements `UIAccessibilityReadingContent` and marks
  the view `.staticText` — `iOSTerminalView.swift:301-313, 2943+`), so
  this is a specific, narrow gap (keyboard visibility control) rather than
  "the terminal is unusable with VoiceOver."

### 6. New terminal output is never announced to VoiceOver
Related to #5: nothing in ssssh or in SwiftTerm posts a
`UIAccessibility.post(notification: .announcement, ...)` (or similar) when
new output streams in. SwiftTerm only posts `.pageScrolled` on scroll and
`.layoutChanged` on resize (`iOSTerminalView.swift:1726`,
`AppleTerminalView.swift:1848`). A VoiceOver user waiting on a long-running
remote command has no signal that it finished, or that a new prompt
appeared, without manually re-entering the terminal element and reading
forward. This is a known-hard problem for terminal emulators in general
(you don't want to announce every byte), but even a coarse signal —
e.g. announcing when the connection state changes, which `TerminalSessionView`
already tracks via `connection.state` (`TerminalSessionView.swift:33-42`)
— is currently not surfaced to VoiceOver at all; those state changes are
purely visual (`StatusBanner`).

### 7. Color-only session status has a text fallback, but the dot itself is unnecessary VoiceOver noise
`SessionsListView.statusDot(for:)` (`SessionsListView.swift:66-74`) draws
an 8×8pt colored circle (green/yellow/red) with no accompanying
accessibility label, sitting next to `statusText(for:)` which already
spells out "Connecting…"/"Connected"/"Disconnected"/the failure message
(`SessionsListView.swift:25-28, 57-64`). This is **not** a color-only
information problem — the text is already there — but the undecorated dot
is a stray, unlabeled shape that VoiceOver may announce as an anonymous
"image" alongside the row. Low severity; worth `.accessibilityHidden(true)`
as a cheap cleanup rather than a real usability bug.

---

## Usability (discoverability, error clarity, forms)

### 8. New users can get stuck on "Copy Key to Server" with no explanation
`CopyKeyToServerView` (`Hosts/CopyKeyToServerView.swift:22-28, 42`)
presents a `Picker("Key", selection:)` populated from `keyStore.keys`, and
disables the "Copy Key to Server" button whenever `selectedKeyID == nil`.
If the user hasn't generated any key yet, the picker has zero rows,
`selectedKeyID` resolves to `nil` in `.onAppear`
(`CopyKeyToServerView.swift:58-62`), and the button sits disabled with no
visible explanation — the `result`-driven error `Text` only appears after
a failed attempt (`CopyKeyToServerView.swift:44-46`), never for "you have
no keys yet." A first-time user who reaches this screen before visiting
the Keys tab has no clue why the flow won't proceed.

### 9. Onboarding order works against how the app is actually organized
The tab order is Hosts → Sessions → Keys → Settings
(`ContentView.swift:13-24`), and Hosts is the default landing tab. But a
host is only useful once it has a key (or you go through the
password-based Copy Key flow, which itself needs a key — see #8). A
brand-new user's first screen is an empty Hosts list
(`ContentUnavailableView("No Hosts Yet", ..., description: "Add a host to
connect to.")`, `HostListView.swift:17-23`) that doesn't mention that a
key is worth creating first. There's no first-run walkthrough anywhere in
`sssshApp.swift`/`ContentView.swift` connecting the two concepts.

### 10. Empty states describe the next action but don't offer it
Both `HostListView`'s and `KeyListView`'s `ContentUnavailableView` give a
description ("Add a host to connect to." / "Generate a key to get
started.") but no button — the actual add/generate control is the small
"+" in the navigation bar's `.primaryAction` toolbar slot
(`HostListView.swift:76-87`, `KeyListView.swift:39-50`). This is a common
enough iOS pattern that most users will find it, but pairing the empty
state's own text with an inline action button (`ContentUnavailableView`
supports an `actions:` closure) would remove the extra hop for first
launch specifically.

### 11. Auto-reconnect can trigger a Face ID/passcode prompt with no visible context, and can stack multiple prompts
`Keychain.load` (`Keychain.swift:51-68`) requires a fresh biometric or
passcode authentication on every call — there is no caching/re-use window
configured on the `LAContext`. `SSHConnection.connect(keyStore:hostKeyStore:)`
(`SSHConnection.swift:128-152`) calls `keyStore.privateKeyMaterial(for:)` →
`Keychain.load` on *every* connect, including ones the user didn't just
initiate by hand:
- `SessionManager.reconnectIfNeeded()` (`SessionManager.swift:43-47`),
  called automatically whenever the app returns to the foreground
  (`ContentView.swift:27-31`), calls `connect` for every dropped session.
- `SSHConnection.reconnectWithBackoff` (`SSHConnection.swift:109-119`)
  does the same after a network blip, with no user action at all.

So: bring the app back from the background with two dropped sessions, and
the user can get hit with a Face ID prompt (or two, queued) the instant
the app becomes active, with no on-screen text yet explaining what's
happening or why. Not wrong to require re-authentication for key
material, but the lack of any "Reconnecting to home-server…" framing
around the prompt makes it feel like an interruption rather than an
expected consequence of reopening the app.

### 12. Destructive/loading button states don't distinguish "still loading" from "here's a price, but you can't tap it"
`PaywallView.purchaseButton` (`PaywallView.swift:87-118`) falls back to
static text (`fallbackTitle`/`fallbackPrice`, e.g. "Unlock Forever —
$9.99") whenever StoreKit's `Product` hasn't loaded yet, but the button is
simultaneously `.disabled(product == nil || ...)`
(`PaywallView.swift:117`). A user sees what looks like a fully-formed,
priced purchase button that simply doesn't respond to taps, with nothing
distinguishing "StoreKit is still fetching product info" from "this
button is broken." A lightweight loading indicator (or graying the price
text itself) when `product == nil` would make the disabled state
legible.

### 13. Forms don't chain focus or support Return-to-advance
None of `HostEditView`, `KeyListView`'s `GenerateKeyView`, or
`CopyKeyToServerView` use `@FocusState` or `.onSubmit` (a repo-wide grep
for `FocusState`/`onSubmit`/`onKeyPress`/`UIKeyCommand`/`keyboardShortcut`
across `Sources` returns nothing). In `HostEditView.swift:36-49`, for
example, filling in Nickname → Hostname → Port → Username requires
tapping into each field by hand; hitting Return in one doesn't advance to
the next, and there's no keyboard shortcut for Save/Cancel on iPad with a
hardware keyboard. This mostly costs sighted, touch-only users a few
extra taps, but it's a bigger cost for anyone using Switch Control, Voice
Control, or a hardware keyboard, where field-to-field focus chaining is
the expected iOS idiom.

### 14. Same StoreKit/keychain errors surface via `localizedDescription` everywhere, which is consistent but occasionally cryptic
`HostEditView.swift:109`, `GenerateKeyView` (`KeyListView.swift:104`),
`CopyKeyToServerView.swift:93`, and `PurchaseManager`'s three catch sites
all funnel errors through `error.localizedDescription` into a plain red
`Text`. This is a reasonable, consistent pattern and the app-specific
errors it wraps are already worded well (e.g. `SSHConnectionError
.noKeyConfigured`: "This host has no key configured. Edit the host and
choose a key.", `SSHConnection.swift:344-350`; the TOFU mismatch message
explicitly says "This could mean someone is intercepting your connection,"
`SSHConnection.swift:337`). The exception is anything that bubbles up
raw from StoreKit or `SecCopyErrorMessageString` — those can render as
opaque strings like an `ASDErrorDomain` code. Not something to chase
proactively, just worth knowing the consistency has a ceiling set by
whatever the underlying framework hands back.

---

## What's already working well

- **Trust-on-first-use flow is clear and accessible.** `HostKeyConfirmationView`
  shows the fingerprint in a `.textSelection(.enabled)` monospaced text
  block (so it can be copied for out-of-band verification) and explicitly
  names the risk ("intercepting your connection") rather than using vague
  security jargon.
- **Non-terminal UI text is Dynamic-Type-friendly by default.** Every list
  row, form field, and button outside the terminal uses semantic text
  styles, so system text-size changes propagate correctly everywhere
  except the terminal itself (see #3).
- **No animation anywhere in the app's own code**, so Reduce Motion has
  nothing to conflict with today.
- **Keychain access control is a genuinely good security default**
  (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, biometry-or-passcode,
  never iCloud-synced) — the concern above (#1, #11) is about the *UI*
  around that default, not the default itself.
- **Subscription/legal disclosure already meets App Store guidelines**
  (visible renewal terms + Terms of Use/Privacy Policy links directly on
  the paywall, `PaywallView.swift:49-59`) — this was previously fixed
  per the repo's commit history and remains correct.
- **Icon-and-text `Label(...)` is used consistently** for toolbar buttons,
  swipe actions, and context menu items, so VoiceOver gets a real spoken
  label everywhere even where the visible UI only shows an icon (e.g. the
  "+" toolbar buttons).

---

## Summary table

| # | Finding | Area | Severity |
|---|---|---|---|
| 1 | Key deletion is instant, no confirmation, no backup/export | Data safety | Critical |
| 2 | Host delete / "Forget Known Host Key" have no confirmation | Data safety / security | Critical |
| 3 | Terminal text size ignores Dynamic Type entirely | Accessibility | Major |
| 4 | High Contrast / Reduce Transparency are manual-only, not system-linked | Accessibility | Major |
| 5 | Keyboard show/hide gesture is unreachable under VoiceOver, no fallback control | Accessibility | Major |
| 6 | No VoiceOver announcement for new terminal output or connection state changes | Accessibility | Minor–Major |
| 7 | Unlabeled status dot is redundant VoiceOver noise | Accessibility | Minor |
| 8 | "Copy Key to Server" gives no guidance when the user has zero keys | Usability | Major |
| 9 | Tab order/onboarding doesn't guide Key-before-Host | Usability | Minor |
| 10 | Empty states describe but don't offer the next action | Usability | Minor |
| 11 | Auto-reconnect can trigger unexplained/stacked Face ID prompts | Usability | Major |
| 12 | Disabled paywall buttons don't distinguish loading vs. broken | Usability | Minor |
| 13 | No focus-chaining/`onSubmit`/keyboard shortcuts in forms | Usability / Accessibility | Minor–Major |
| 14 | Raw framework error strings occasionally leak through | Usability | Minor |

---

*This report intentionally stops at findings — no code changes were made.
File:line references are current as of the audit (branch `main`,
commit `758eefc`).*
