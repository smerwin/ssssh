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

## Platform

- iOS 17 / iPadOS 17+, SwiftUI, Swift 6.
- iPhone and iPad in one universal target. No Mac Catalyst, no watch/TV
  targets.
- External keyboard support (full-size and Magic Keyboard) is a first-class
  input path, not an afterthought, since the on-screen keyboard is the weak
  link for terminal use.

## Core features

### 1. Key management

- Default algorithm: **Ed25519**. Offer ECDSA (P-256/384) as a fallback for
  legacy servers; do not offer plain RSA or DSA in the generation UI (import
  of existing RSA keys is still supported for compatibility).
- Keys are generated on-device and the private key material never leaves the
  device unencrypted. Private keys are stored in the iOS Keychain with
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, and gated behind Face
  ID/Touch ID (`LAContext`) before use.
- Support multiple keys (e.g. "personal", "work"), each with a label, a
  creation date, and a list of hosts it's been deployed to.
- Public key export via share sheet, copy-to-clipboard, and QR code (useful
  for pasting into a GitHub/GitLab account or a cloud provider's console from
  another device).
- Optional passphrase on the private key, on top of Keychain/biometric
  protection.

### 2. Copy key to server

- A guided flow equivalent to `ssh-copy-id`:
  1. User enters host, port, username, and authenticates once with a
     password (or an existing key).
  2. App opens a session, ensures `~/.ssh` exists with `0700`, appends the
     selected public key to `~/.ssh/authorized_keys` if not already present,
     and sets `0600` on the file.
  3. App confirms success by reconnecting with the new key before reporting
     done.
- Never stores the password used for this step; it lives only in memory for
  the duration of the operation.

### 3. Terminal

- Full terminal emulation (xterm/VT100 control sequences), not a
  command-and-response box — curses apps must render correctly.
- Visual theme: green-on-black CRT look by default (subtle scanline/glow
  effect, toggle-able), with a plain high-contrast theme as an alternative
  for accessibility.
- An accessory row above the keyboard for keys iOS doesn't expose:
  `Esc`, `Tab`, `Ctrl`, arrow keys, `Ctrl+C`, and a long-press for less common
  keys (`Ctrl+A/E/K/U`, function keys). Ctrl acts as a modifier chord with the
  next tap.
- Multiple concurrent sessions as tabs, each independent and backgroundable;
  reconnect-on-resume when the app returns to foreground (sessions don't
  survive a full app kill, to keep scope small).
- Copy/paste and text selection tuned for terminal content (rectangular
  selection is a stretch goal, not required for v1).

### 4. Hosts and connections

- Saved host profiles: nickname, hostname/IP, port (default 22), username,
  which key to authenticate with, and an optional startup command
  (e.g. `tmux attach || tmux new`).
- Standard `known_hosts` verification — new host keys prompt a
  fingerprint-confirmation dialog (TOFU), changed host keys block the
  connection with a clear warning instead of silently proceeding.
- No cloud sync of host profiles or keys in v1 — everything is local to the
  device. (iCloud Keychain sync of the private keys themselves is a plausible
  v1.1 addition, off by default.)

## Non-goals (v1)

- SFTP/file browser
- Port forwarding / tunneling UI
- Mosh support
- Snippet libraries, scriptable automation, or a command palette
- Team/shared host or key management

These are reasonable follow-ups once the core loop (generate → deploy → use)
is solid, but they add real surface area and aren't needed to be useful.

## Building

The Xcode project is generated from `project.yml` via
[XcodeGen](https://github.com/yonaskolb/XcodeGen) — `ssssh.xcodeproj` is
gitignored, not checked in.

```
brew install xcodegen   # once
xcodegen generate       # whenever project.yml changes
open ssssh.xcodeproj
```

Swift package dependencies (SwiftTerm, Citadel) resolve automatically on
first build.

## Architecture sketch

- **UI**: SwiftUI throughout. One tab-bar app: Hosts, Keys, and active
  Terminal sessions.
- **SSH transport**: a pure-Swift SSH implementation (e.g. Citadel, built on
  SwiftNIO) rather than wrapping libssh2/NMSSH, to avoid a C dependency and
  get async/await-native APIs. Needs to support Ed25519 auth, exec/shell
  channels with PTY allocation, and window resizing.
- **Terminal emulation**: SwiftTerm (or equivalent VT100/xterm emulator with
  an existing Swift/UIKit view) for rendering and input handling, driven by
  the PTY byte stream from the SSH channel.
- **Key storage**: Keychain Services directly; no custom crypto for key
  generation — use `CryptoKit`'s `Curve25519.Signing.PrivateKey` for Ed25519
  generation and export in standard OpenSSH wire/PEM format.
- **Persistence**: host profiles and key metadata in a small local store
  (SwiftData or a plain Codable JSON file) — no server, no account system.

## Data model (sketch)

- `SSHKey`: id, label, algorithm, createdAt, publicKeyOpenSSH, keychainRef,
  deployedHosts: [HostID]
- `Host`: id, nickname, hostname, port, username, keyID, startupCommand?,
  knownHostFingerprint
- `Session` (runtime only, not persisted): hostID, PTY size, connection
  state, scrollback buffer

## Security notes

- Private keys never leave the device and are never transmitted, backed up
  unencrypted, or logged.
- Host key verification is mandatory; there is no "always trust" bypass.
- Biometric gate on private key use is required, not optional, given the
  blast radius of a stolen key.
- The `ssh-copy-id` flow's password path is the single highest-risk piece of
  code in the app (handles a plaintext credential, however briefly) and
  deserves the most scrutiny/testing.

## Suggested milestones

1. **Key management**: generate, store, list, export/QR a key. No
   networking yet.
2. **Connect + terminal**: SSH auth with an existing/imported key, PTY shell,
   SwiftTerm rendering, accessory keyboard row. This is the "does it actually
   work as a terminal" milestone — test against `vim` and `tmux`.
3. **Copy key to server**: password-authenticated bootstrap flow described
   above.
4. **Host management polish**: saved profiles, known_hosts/TOFU handling,
   session tabs, reconnect-on-resume.
5. **Theming**: green CRT mode, accessibility theme, app icon/branding.
