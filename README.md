# ssssh

smerwin's simple ssh — a minimal, native SSH client for iPhone and iPad.

## What it does

Three things, done well:

1. **Generate modern SSH keys** on-device and keep them safe.
2. **Copy a key to a server** the way `ssh-copy-id` does, without touching a
   desktop.
3. **Open a real terminal** to that server — green phosphor text on black,
   full PTY support for curses apps like `vim`, `tmux`, and `htop`.

Everything else (SFTP browsing, port forwarding, Mosh, config sync) is
explicitly out of scope for v1. This is a terminal, not an IDE.

## Why does it do this

I had to sudo something for Claude the other day and I was away from my laptop.

## Pricing

Free: one host, one key. A one-time $9.99 in-app purchase (or a $0.99/month
subscription, if you'd rather support ongoing development) unlocks
unlimited hosts and keys. Either purchase grants the same entitlement --
see `Sources/Purchases/PurchaseManager.swift`.

Yes, you can just download and compile this yourself and skip the pricing.
I charge money at all just to try and recoup my apple developer account spend.
You could even just knock your own together in a day with Claude like I did,
or you can clone this repo and save a few tokens on the boring work. 

## License

This source is available under the [PolyForm Noncommercial License
1.0.0](LICENSE.md): you're free to clone it, read it, compile it, run it,
and modify it for any noncommercial purpose (personal use, learning,
contributing back) at no cost. Any commercial use -- reselling it,
distributing your own build, running it as part of a paid product or
service -- isn't covered by this license and needs permission from the
author. The official build on the App Store is sold separately by the
author, who as copyright holder isn't bound by the license granted to
everyone else.

SwiftTerm and Citadel, the two dependencies this app is built on, are both
MIT-licensed; their required notices are preserved in [NOTICE.md](NOTICE.md).

## Platform

- iOS 17 / iPadOS 17+, SwiftUI, Swift 6 language mode.
- iPhone and iPad in one universal target. No Mac Catalyst, no watch/TV
  targets.
- Keyboard accessory row (Esc/Tab/Ctrl/arrows/function keys) comes from
  SwiftTerm's built-in `TerminalAccessory`, not custom-built — it was
  already exactly what the spec asked for, so there was no reason to
  reinvent it.

## Core features

### 1. Key management

- Ed25519 (via `CryptoKit.Curve25519.Signing.PrivateKey`), ECDSA P-256, and
  ECDSA P-384 generation, all on-device. Private key bytes are stored in the
  Keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`), gated behind a
  Face ID/Touch ID (or device passcode) prompt on every use via
  `kSecAttrAccessControl`, and never leave the Keychain; `KeyStore` only
  ever hands out a typed, reconstituted `SSHPrivateKeyMaterial` value to the
  SSH layer, never raw key bytes.
- Multiple keys, each with a label, algorithm, creation date, and a list of
  host IDs it's been deployed to (`KeyStore`, `SSHKey`).
- Public key export via `KeyDetailView`: QR code (CoreImage), copy to
  clipboard, and the system share sheet.
- RSA exists as an enum case (`SSHKeyAlgorithm.rsa`) reserved for future
  import support, but there's no import UI yet -- see "Known gaps."

### 2. Copy key to server

- `SSHCopyID.copyKey` implements the guided `ssh-copy-id` flow for real:
  connects with password auth (Citadel), runs a single idempotent remote
  command to create `~/.ssh` (`0700`) and append the public key to
  `authorized_keys` (`0600`) if it isn't already there, then reconnects
  using the new key to confirm it actually works before reporting success.
- The key line is shipped base64-encoded and decoded remotely into a shell
  variable, so its contents never need shell-escaping.
- The password is a local variable for the duration of the call; it's never
  written to disk or logged.

### 3. Terminal

- `SSHConnection` wraps a real Citadel `SSHClient`: pubkey auth (Ed25519 or
  ECDSA), PTY allocation (`SSHChannelRequestEvent.PseudoTerminalRequest`),
  and a bidirectional byte stream wired directly into SwiftTerm's
  `TerminalView` (`TerminalSessionView`) -- keystrokes out via
  `TerminalViewDelegate.send`, output in via `TerminalView.feed`, resize
  events forwarded both ways.
- Verified against a real OpenSSH server (a throwaway Docker container, not
  just unit tests): password auth, key deployment, pubkey auth, and an
  interactive PTY echo all round-tripped correctly end to end.
- Visual theme: green or amber phosphor CRT looks (both with the subtle
  `ScanlineOverlay`) plus a plain high-contrast alternative, toggled from
  the Settings tab and persisted via `@AppStorage`.
- Swipe down on the terminal to page up through scrollback (or send a real
  page-up keystroke to full-screen apps like `vim`/`less`); swipe up to
  page back down toward the live output. The keyboard's own show/hide is a
  toolbar button instead, next to the terminal's title.
- Copy/paste and OSC 52 clipboard support come from SwiftTerm's built-in
  defaults, not custom code; rectangular selection isn't implemented.
- Sessions persist independent of navigation: `SessionManager` keeps one
  `SSHConnection` per host alive regardless of which view is on screen, and
  reconnects any dropped session when the app returns to the foreground
  (`scenePhase` -> `.active`) regardless of the Auto-Reconnect setting below
  -- the user foregrounding the app is itself a signal they want back in.
- **Auto-Reconnect** (Settings, on by default): when a session drops
  unexpectedly (network blip, remote hangup, auth failure) while the app is
  already in the foreground, it's automatically reconnected with
  exponential backoff (1s, 2s, 4s, ... capped at 30s, reset after a
  successful connect) if this is on; if it's off, the dropped session is
  torn down and removed from the Sessions list instead of lingering in a
  disconnected state. There's no hard retry *limit* -- a persistently
  broken host (revoked key, permanently unreachable) will keep retrying
  forever, just slowly, rather than eventually giving up. Never fires for
  a *clean* end to the shell (typing `exit`/`logout`, or Ctrl+D) --
  reconnecting the instant someone deliberately logs out would be exactly
  the wrong behavior.
- **Verbose Connecting** (Settings, on by default): narrates each
  connection lifecycle step (connecting, authenticating, requesting a
  pty) as `debug1:`-style lines in the terminal itself while a session
  connects, similar to `ssh -v`. Citadel/NIOSSH don't log the actual
  handshake internals (key exchange, algorithm negotiation) at all, so
  this can't show true protocol-level detail -- it narrates the lifecycle
  steps the app itself controls, not a tap into lower-level logging.

### 4. Hosts and connections

- Add/edit sheets (`HostEditView`) for nickname, hostname, port, username,
  which key to use, and an optional startup command.
- Trust-on-first-use host key verification (`HostKeyStore`,
  `TOFUHostKeyValidator`): a new host's SHA256 fingerprint is shown in a
  real confirmation dialog before it's trusted and persisted; a host whose
  key has since changed fails the connection outright with no
  in-the-moment override -- the only way back in is explicitly "forgetting"
  the known host key from its context menu.
- A "Sessions" tab lists every host with a live or recent connection and
  lets you jump back into any of them -- the practical equivalent of
  browser-style tabs, implemented as a list/switcher rather than a
  dynamic `TabView`.
- No cloud sync of host profiles or keys -- everything is local
  (`Application Support/hosts.json`, `keys.json`, `known_hosts.json`).

## Non-goals (v1)

- SFTP/file browser
- Port forwarding / tunneling UI
- Mosh support
- Snippet libraries, scriptable automation, or a command palette
- Team/shared host or key management

These are reasonable follow-ups once the core loop (generate → deploy → use)
is solid, but they add real surface area and aren't needed to be useful.

## Known gaps

Things the original spec described that aren't actually implemented yet --
worth knowing before relying on them:

- **No passphrase support** on generated private keys, on top of Keychain
  protection.
- **No RSA or ECDSA import**, only Ed25519 (Keys tab > New Key > Import
  Key, file-picker only -- no paste). See CLAUDE.md for why RSA/ECDSA
  import isn't a small addition.
- **No rectangular text selection** in the terminal.

## Building locally

Prerequisites: Xcode 16+, and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

```
git clone git@github.com:smerwin/ssssh.git
cd ssssh
xcodegen generate   # produces ssssh.xcodeproj from project.yml
open ssssh.xcodeproj
```

Then build/run the `ssssh` scheme like any other Xcode project. Swift
package dependencies (SwiftTerm, Citadel) resolve automatically on first
build -- no extra setup.

**`project.yml` is the source of truth, not `ssssh.xcodeproj`.** Don't hand-edit
the `.xcodeproj`. After changing `project.yml`:

```
xcodegen generate
git add ssssh.xcodeproj   # the regenerated project IS committed -- see below
```

Two things worth knowing before touching the project setup:

- **`ssssh.xcodeproj` is checked into git** (only `xcuserdata` inside it is
  ignored), unlike XcodeGen's usual recommendation to gitignore it. This is
  required for Xcode Cloud, which needs a real project file present in the
  repo to discover a workflow at all -- if it's missing, Cloud fails with
  "Project ssssh.xcodeproj does not exist at the root of the repository."
- **XcodeGen 2.45.4's top-level `resources:` target key silently produces no
  Resources build phase** on this project (a real, confirmed bug, not a
  config mistake) -- the app icon and accent color are wired in via a
  `sources` entry with an explicit `buildPhase: resources` override instead.
  Don't switch this back to a plain `resources:` list without re-verifying
  the built app actually contains `Assets.car` and `CFBundleIconName`.

## Architecture

- **UI**: SwiftUI throughout. Four tabs: Hosts, Sessions, Keys, Settings.
- **SSH transport**: [Citadel](https://github.com/orlandos-nl/Citadel)
  (built on SwiftNIO/NIOSSH) for async/await-native Ed25519/ECDSA auth, PTY
  shells, and password auth for the copy-id flow.
- **Terminal emulation**: [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)
  for VT100/xterm rendering, input handling, and the keyboard accessory row.
- **Key storage**: Keychain Services directly (`Common/Keychain.swift`);
  key generation via `CryptoKit`, exported as standard OpenSSH wire-format
  `authorized_keys` lines.
- **Persistence**: host profiles, key metadata, and trusted host-key
  fingerprints as plain Codable JSON files under Application Support -- no
  SwiftData, no server, no account system.
- **Concurrency**: `SSHConnection` and `HostKeyStore` are `@MainActor` and
  `@Observable` for UI binding, but Citadel's own types (`SSHClient`,
  `SSHAuthenticationMethod`, `TTYStdinWriter`) aren't Sendable-audited, so
  the actual connect/PTY-read work runs in a detached, non-isolated task
  that hops back to the main actor only to publish `state`/`onOutput`. See
  the doc comments on `SSHConnection` and `HostKeyStore` for the reasoning.

## Data model

- `SSHKey`: id, label, algorithm, createdAt, publicKeyOpenSSH,
  deployedHostIDs
- `SSHHost` (named to avoid colliding with Foundation's own `Host` class):
  id, nickname, hostname, port, username, keyID, startupCommand. Trusted
  host-key fingerprints live separately in `HostKeyStore`
  (`known_hosts.json`), keyed by host ID -- not on this struct.
- `SSHConnection` (runtime only, not persisted): host, connection state,
  output callback -- one instance per host, owned by `SessionManager`

## Security notes

- Private keys never leave the device and are never transmitted, backed up
  unencrypted, or logged.
- Host key verification is mandatory; there is no "always trust" bypass --
  see "Hosts and connections" above.
- The `ssh-copy-id` flow's password path is the single highest-risk piece of
  code in the app (handles a plaintext credential, however briefly) and
  deserves the most scrutiny/testing.
- See "Known gaps" for the passphrase protection the original spec called
  for but that isn't implemented yet.
