# CLAUDE.md

Working notes for anyone (human or agent) making changes in this repo. See
`README.md` for what the app actually does and its current status; this
file is about *how to work here* without rediscovering the same gotchas.

## Project shape

- SwiftUI iOS/iPadOS app, Swift 6 language mode, strict concurrency.
- `project.yml` is the source of truth for the Xcode project, via
  [XcodeGen](https://github.com/yonaskolb/XcodeGen). `ssssh.xcodeproj` is
  generated from it -- **never hand-edit the `.xcodeproj`**.
- Unusually, the generated `ssssh.xcodeproj` **is committed to git** (only
  `xcuserdata` inside it is ignored). This is not XcodeGen's normal
  recommendation, but Xcode Cloud needs a real project file present at the
  repo root to discover a workflow at all -- without it, Cloud fails with
  "Project ssssh.xcodeproj does not exist at the root of the repository."

**After changing `project.yml` or adding/removing/renaming any source
file**, regenerate and commit the result:

```
xcodegen generate
git add ssssh.xcodeproj
```

XcodeGen's classic (non-synchronized-folder) mode does not auto-discover
new files in a referenced directory -- it lists each file explicitly in
the `.pbxproj`, so skipping regeneration after adding a file means it
silently won't be compiled.

## Building and testing

```
xcodegen generate
xcodebuild -project ssssh.xcodeproj -scheme ssssh \
  -destination 'generic/platform=iOS Simulator' -configuration Debug build

xcodebuild test -project ssssh.xcodeproj -scheme ssssh \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

Tests use Swift Testing (`import Testing`, `@Test`, `#expect`), not XCTest,
in the `sssshTests` target. `-only-testing:sssshTests/SomeSuite/someTest`
has been flaky at correctly targeting Swift Testing struct-based tests in
this setup (a run reported "0 tests executed" with no error) -- if that
happens, fall back to running the whole suite rather than chasing the
identifier syntax.

### Known one-time environment requirements

- `brew install xcodegen`
- Xcode's Metal Toolchain component (`xcodebuild -downloadComponent
  MetalToolchain`) -- SwiftTerm ships a Metal shader and archiving fails
  without it if it's not already installed.

## Real bugs found in this codebase's history (don't reintroduce)

- **XcodeGen's top-level `resources:` target key silently produces no
  Resources build phase** on this project (confirmed real bug in XcodeGen
  2.45.4, not a config mistake). The app icon and accent color are wired in
  via a `sources` entry with an explicit `buildPhase: resources` override
  instead. If you ever "simplify" this back to a plain `resources:` list,
  rebuild and check the archived app actually contains `Assets.car` and
  `CFBundleIconName` -- it silently won't, and the icon will pass local
  Xcode installs fine while failing real App Store Connect validation with
  "Missing required icon file" errors.
- **`return` inside a `MainActor.run { }` closure only exits the closure,
  not the enclosing function.** This exact bug shipped once in
  `HostKeyStore.evaluate` -- the early-return for an already-trusted host
  was written this way, so the host-key confirmation dialog fired on
  *every* connection instead of only the first. If you see a pattern like
  `try await MainActor.run { if condition { return } }` followed by more
  code, check whether that fall-through is intended.
- **`@Observable` + `nonisolated(unsafe)` don't reliably compose.** The
  `@Observable` macro rewrites stored properties into its own generated
  storage; `nonisolated(unsafe)` on the original declaration doesn't always
  carry through to that storage (some toolchains warn "has no effect" and
  still treat it as actor-isolated, which then fails to compile at the
  point it crosses into a nonisolated context). Non-Sendable state that
  needs to live outside main-actor isolation (see `SSHConnection`'s
  `SSHNetworkState`) belongs in a plain, non-`@Observable`, non-actor class
  instead -- its stored properties have no macro rewriting, so there's no
  ambiguity.
- **Conforming one class to two UIKit-ish delegate protocols can trigger
  actor-isolation inference conflicts.** Making `TerminalSessionView`'s
  `Coordinator` conform to both `UIGestureRecognizerDelegate` and
  SwiftTerm's `TerminalViewDelegate` produced "conformance ... crosses into
  main actor-isolated code and can cause data races" -- conforming to a
  `@MainActor`-refined protocol (`UIGestureRecognizerDelegate` in recent
  SDKs) makes the compiler infer the whole type as main-actor-isolated,
  which then conflicts with the other protocol's nonisolated requirements.
  Fix was to split the gesture delegate onto its own tiny standalone object
  rather than fighting the inference. If you see this error, try that
  split before reaching for `nonisolated` annotations everywhere.
- **UIKit methods like `resignFirstResponder()`/`becomeFirstResponder()`
  are main-actor-isolated in this SDK.** Calling them from a plain
  nonisolated method (e.g. an `@objc` gesture-recognizer target-action
  handler on a deliberately-nonisolated `Coordinator`) warns about crossing
  isolation. Mark the specific handler method `@MainActor` rather than the
  whole class, matching what's already done for `attach(view:connection:)`
  on the same type.
- **Citadel's `SSHClient` and `TTYStdinWriter` aren't Sendable-audited.**
  `TTYStdinWriter` wraps a NIO `Channel`, which only conforms to NIO's
  transitional `_NIOPreconcurrencySendable` marker, not real `Sendable`,
  under Swift 6 strict concurrency; `SSHClient` isn't marked at all despite
  internally marshaling its work onto the correct event loop the same way.
  Rather than fighting this call-site by call-site, `CitadelSendability.swift`
  retroactively asserts `@unchecked @retroactive Sendable` for both. If a
  new Citadel type needs to cross an isolation boundary and the compiler
  complains about "sending X risks causing data races," check there first
  before restructuring code around it.
- **SwiftTerm already uses single-finger double-tap internally** (for word
  selection). Don't add a second single-finger double-tap gesture recognizer
  on top of `TerminalView` -- it competes with SwiftTerm's own. This is why
  the terminal's scrollback-paging gesture (`TerminalSessionController`'s
  swipe up/down, see `TerminalViewStore.swift`) is swipe-only, not
  double-tap.
- **`.ignoresSafeArea(edges: .bottom)` without specifying `regions:`
  ignores both the device's own safe area (home indicator) *and* the
  keyboard's safe area.** That second part is easy to miss and will make
  SwiftUI stop shrinking a view for the keyboard. Use
  `.ignoresSafeArea(.container, edges: .bottom)` to get only the home-
  indicator behavior.
- **`Picker(_:selection:)` with `.pickerStyle(.inline)` renders the
  Picker's own string label as an extra, unselectable row** above the real
  options inside a `Form` `Section`. Give it `label: { EmptyView() }`
  instead of a string label; the `Section` header already provides
  context.

## Importing RSA/ECDSA private keys (not implemented -- here's why)

`KeyListView`'s import flow (`KeyImporter.swift`) only supports Ed25519,
file-picker only (deliberately no paste field -- see the doc comment on
`ImportKeyView`). RSA and ECDSA P-256/P-384 import were left out after
investigating Citadel's public API, not just "nobody got to it yet" --
here's the actual constraint, for whoever picks this up next:

- **ECDSA P-256/P-384**: Citadel can *detect* these key types
  (`SSHKeyDetection.detectPrivateKeyType`) but has no public initializer
  to decode one into a `P256.Signing.PrivateKey`/`P384.Signing.PrivateKey`
  the way it does for Ed25519
  (`Curve25519.Signing.PrivateKey.init(sshEd25519:decryptionKey:)`).
  You'd be writing an OpenSSH-private-key-format decoder for these curves
  from scratch.
- **RSA**: Citadel *can* decode a pasted/imported RSA key into a working
  `Insecure.RSA.PrivateKey` (`init(sshRsa:decryptionKey:)`) -- enough to
  authenticate with immediately -- but that type has no public way to get
  the key back out as `Data`. Its actual material (`privateExponent`,
  `modulus`, etc.) is stored as raw BoringSSL `BIGNUM` pointers marked
  `internal` to Citadel, not `public`. So there's no way to serialize an
  imported RSA key into the Keychain the way every other key in this app
  is stored (`KeyStore.persist`, `Keychain.swift`) -- one raw-bytes blob,
  one Face ID prompt, no passphrase ever re-entered after import.

  Making RSA import "stick" across an app relaunch needs one of:
  1. Store the *encrypted* key file itself plus its passphrase (a second
     Keychain item), decrypting fresh on every use -- works, but it's a
     real behavior difference from every other key in this app (two
     stored secrets instead of one), and wants product buy-in before
     building it.
  2. Reach past Citadel's public API into its internal BoringSSL
     plumbing, or write an OpenSSH-private-key-format parser from
     scratch to get at the raw integers -- exactly the kind of
     reinventing-crypto-parsing this app has otherwise avoided by
     leaning on Citadel.

  Neither was picked here. If you want RSA import, start by deciding
  between those two, not by looking for a third way around Citadel --
  there wasn't one as of Citadel 0.7.x.

## Concurrency architecture (why the SSH code looks the way it does)

`SSHConnection` and `HostKeyStore` are `@MainActor @Observable` for UI
binding, but Citadel's types aren't Sendable-safe, so the actual
connect/PTY-read work runs in a `Task.detached`, nonisolated function
(`SSHConnection.runSession`) that hops back to the main actor only for
tiny, explicit moments (`await MainActor.run { self.state = ... }`) to
publish state or output. Read the doc comments on `SSHConnection`,
`HostKeyStore`, and `CitadelSendability.swift` before changing this --
each one documents a specific compiler error it's working around, and
"simplifying" it tends to just reintroduce that error under a different
guise.

## Manual verification against a real SSH server

There's no SSH server mock in this repo; verification against real
protocol behavior has been done with a throwaway Docker container:

```
docker run -d --name ssssh-test-sshd -p 2222:2222 \
  -e PUID=1000 -e PGID=1000 -e PASSWORD_ACCESS=true \
  -e USER_PASSWORD=testpass123 -e USER_NAME=testuser -e TZ=Etc/UTC \
  lscr.io/linuxserver/openssh-server:latest
```

Notes if you do this again:
- The container's *actual* active sshd config is at `/config/sshd/sshd_config`
  inside the container, not `/etc/ssh/sshd_config` -- editing the latter has
  no effect.
- `Process`/`NSTask` is **not available on iOS** (macOS-only), so a Swift
  Testing test running in the iOS Simulator can't shell out to `docker`
  itself to simulate a drop. Either drive Docker from the host Mac's own
  shell with timing coordinated against the test's log output, or write a
  standalone macOS SwiftPM executable (as was done to verify the original
  connect/copy-id/PTY flow end-to-end) that imports the same dependencies
  directly.
- Clean up (`docker rm -f`) throwaway containers when done; don't leave
  them running as stray state on the user's Mac.

## Support FAQ

Things that look like ssssh bugs from a screenshot but aren't -- don't "fix"
these client-side without re-reading this first:

- **A highlighted/reverse-video `%` appears alone on its own line after
  connecting, or after some command output.** That's zsh's own
  `PROMPT_EOL_MARK` -- it prints that marker whenever the previous line of
  output (often sshd's `Last login: ...` banner) didn't end with a
  trailing newline, so the next prompt visibly starts on a forced fresh
  line. Every terminal client shows this connecting to a Mac (Terminal.app,
  iTerm2, etc.) -- it isn't something ssssh is injecting, and trying to
  detect-and-strip a bare `%` client-side would be guessing at intent and
  risks eating a real `%` a program actually printed. The real fix is
  server-side, in the *remote* Mac's `~/.zshrc`: `PROMPT_EOL_MARK=""` (or
  `unsetopt PROMPT_SP`).
- **A second `Last login: ...` banner appears mid-line, in the middle of
  existing scrollback, instead of on its own fresh line.** This is what it
  looks like when auto-reconnect succeeds: a brand new SSH login happens
  and the remote shell prints its own new banner, but the terminal
  **intentionally does not clear or reset** on reconnect -- new output
  just keeps appending to the existing scrollback in place. This is a
  deliberate, confirmed decision, not a bug: don't add a `TerminalView`
  clear/reset call to the reconnect path (`SSHConnection.reconnectWithBackoff`,
  `connect()`, or `SessionManager`) to "fix" this.

## Licensing

Source is PolyForm Noncommercial 1.0.0 (see `LICENSE.md`), not an
OSI-approved open-source license -- free for noncommercial use (viewing,
compiling, running, modifying, contributing back), but commercial use
(reselling, distributing a build, bundling into a paid product) needs the
author's permission. The author, as copyright holder, isn't bound by this
and sells the official build separately on the App Store. `NOTICE.md`
preserves the required attribution for the MIT-licensed dependencies
(SwiftTerm, Citadel) regardless of this project's own license.

## Git workflow

- There's a long-lived `dev` branch for frenzy/exploratory commits --
  commit directly to it rather than spinning up a feature branch for
  every small change. It gets merged into `main` occasionally, when
  cutting a release, rather than per-commit.
- Outside of `dev`, work happens on feature branches with PRs into
  `main`, not direct pushes.
- PRs in this repo tend to get reviewed and merged quickly, often while
  a session is still working. **Before starting new, unrelated work, `git
  checkout main && git pull --ff-only`** rather than assuming a
  previously-created branch is still the tip of `main` -- branching from a
  stale local `main` risks silently missing merged work or producing a PR
  with an unexpectedly large diff.
- If you need to bring a few trailing commits from an already-merged
  branch (e.g. work pushed to a branch after its PR was merged), cherry-pick
  them onto a fresh branch off current `main` rather than opening a second
  PR from the old branch -- `git log origin/main..origin/<old-branch>`
  shows exactly what's missing.
