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

## Building your own fork

The README explicitly invites cloning this repo and building it yourself
instead of paying for the App Store build -- that's a supported use case
under the [license](#licensing), not a workaround. If you're an agent
helping someone build their own fork (rather than working in the
author's own checkout), here's what differs:

- **Simulator builds and tests need nothing changed.** `PRODUCT_BUNDLE_
  IDENTIFIER` is hardcoded to `com.smerwin.ssssh` in `project.yml`, but
  the iOS Simulator doesn't enforce code signing, so the plain build/test
  commands above work immediately on a fresh clone, under any Apple ID or
  none at all.
- **In-app purchases work in the Simulator with no Apple Developer
  account.** The scheme is wired to a local StoreKit configuration file
  (`ssssh/Products.storekit`, see `storeKitConfiguration:` in
  `project.yml`), which simulates both products entirely on-device. There
  is no App Store Connect dependency to test the purchase flow.
- **A physical device or an archive build needs real signing**, which
  this repo deliberately does not commit (no `DEVELOPMENT_TEAM` is set in
  `project.yml`, and it's the author's own team -- committing one would
  just make it wrong for everyone else). To build for a device:
  1. Change `PRODUCT_BUNDLE_IDENTIFIER` (both targets) and
     `options.bundleIdPrefix` in `project.yml` to something under your
     own account -- `com.smerwin.ssssh` is already taken by the author's
     App Store listing and won't let you register it.
  2. Add a `DEVELOPMENT_TEAM` setting (your own Team ID) under the
     `ssssh` target's `settings.base` in `project.yml`, or just open the
     regenerated `.xcodeproj` in Xcode once and let "Automatically manage
     signing" fill it in against your signed-in Apple ID.
  3. `xcodegen generate` and rebuild. Don't commit the resulting
     `DEVELOPMENT_TEAM`/bundle ID changes back if you ever intend to send
     a PR upstream -- keep that diff local to your fork, or isolate it in
     its own untracked/ignored config so it doesn't collide with the
     author's values.
- **`ci_scripts/ci_post_clone.sh`, `ci_scripts/ci_pre_xcodebuild.sh`, and
  Xcode Cloud are the author's CI**, keyed to their App Store Connect app
  record. It's harmless to leave in place (both are no-ops unless
  `CI_BUILD_NUMBER` is set by Xcode Cloud itself) but there's no reason to
  try to wire up your own Xcode Cloud run against it -- it won't have
  anywhere to deploy to.
- The [Manual verification](#manual-verification-against-a-real-ssh-server)
  Docker-based SSH server setup below is account-agnostic and works the
  same regardless of whose fork you're building.

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
- **`PurchaseManager.loadProducts()` was only ever called once, from
  `init()`.** A transient failure (no network at cold launch) left
  `lifetimeProduct`/`monthlyProduct` `nil` for the rest of the app
  session -- `PaywallView` shows a perpetual "Loading…" spinner on both
  buttons with no way to recover short of relaunching. `PaywallView` now
  retries via `.task { if both products are still nil, loadProducts()
  again }` on each (re-)presentation, since re-opening the paywall is the
  view's only other chance to retry. Don't assume `PurchaseManager.init()`
  succeeding once is enough -- StoreKit product loading is a network call
  like any other and can fail transiently.
- **`KeyStore.persist`/`delete` used to mutate the Keychain and the JSON
  metadata list in an order where a failure partway through left them
  disagreeing** -- e.g. `persist` appended the new key to the in-memory
  `keys` array (visible immediately, `KeyStore` is `@Observable`) *before*
  the JSON write that could fail, so a metadata-write failure left the key
  listed in the UI while the caller was simultaneously told generation
  failed. `delete` deleted the Keychain item *before* the JSON write that
  could fail, so a metadata-write failure there could leave `keys.json`
  still listing a key whose Keychain material was already gone -- it'd
  reappear (from stale JSON) on next launch and fail the moment it was
  actually used. Fixed by always writing/rolling back metadata (the
  in-memory `keys` array + `keys.json`) *before* the corresponding
  Keychain mutation, not after -- see the doc comments on both methods for
  why that ordering, not the reverse, is the safe one.

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

## Mosh support (in progress -- read before touching `Sources/Mosh`)

The README's Non-goals list used to include Mosh; that's a deliberate scope
change now in progress, not an oversight. `ssssh/Sources/Mosh/` is a real,
working Mosh *protocol* implementation, verified end-to-end against an
unmodified `mosh-server` -- what's missing is entirely the integration into
the app's live terminal UI. Read this whole section before touching
anything in that directory; several of the choices below look like
simplifications you could "clean up," and most of them are load-bearing.

### What's implemented, bottom-up

- `MoshBootstrap` runs `mosh-server new -s` over the existing Citadel SSH
  connection (same pattern as `SSHCopyID`'s `executeCommand`) and parses
  the `MOSH CONNECT <port> <key>` line `mosh-server` prints to stdout. It
  tolerates whatever else rides along on the same combined stdout/stderr
  stream (version banner, locale warnings, the "[mosh-server detached]"
  notice) by scanning line-by-line rather than assuming position.
  `mosh-server` always forks and the parent exits 0 right after printing
  that line (confirmed in its own source, `src/frontend/mosh-server.cc`),
  so this command reliably returns quickly whether or not anything ever
  connects to the server it just started.
  - **Real bug, found connecting to a Mac with mosh installed via
    Homebrew**: a non-interactive SSH exec request (what
    `executeCommand`/`executeCommandStream` both send -- an SSH "exec"
    channel request, not a real interactive session) runs the command via
    the login shell's `-c` mode, *not* `-lc`. On macOS that means
    `~/.zprofile` -- where Homebrew's installer puts its `brew shellenv`
    PATH line -- is never sourced, so `mosh-server` at `/opt/homebrew/bin`
    (Apple Silicon) or `/usr/local/bin` (Intel) is invisible even though
    it's genuinely installed and on the user's own interactive PATH.
    Confirmed directly (`env -i zsh -c 'echo $PATH'` omits
    `/opt/homebrew/bin`; only `zsh -lc` includes it, and only because
    `.zprofile` sources `brew shellenv`). Fixed by prepending well-known
    install locations to `PATH` in the command itself
    (`MoshBootstrap.pathPrefix`) rather than depending on shell
    login/interactive nuances that vary by the remote user's own dotfiles.
  - **A second, related bug the same investigation surfaced**: a
    maximally bare non-interactive shell environment can also leave
    `LANG`/`LC_ALL` completely unset, which makes `mosh-server` itself
    refuse to start ("needs a UTF-8 native locale to run") even once it's
    found. Real mosh's own client solves this by forwarding the *client's*
    actual locale via repeated `-l NAME=VALUE` flags on `mosh-server new`;
    this app has no equivalent client-side locale concept, so
    `MoshBootstrap.detect` tries the plain command first and only retries
    once with a hardcoded `-l LANG=en_US.UTF-8 -l LC_ALL=en_US.UTF-8` if
    the specific locale failure message comes back (`Citadel.SSHClient
    .CommandFailed` only carries an exit code, not the command's output,
    so this required switching from `executeCommand` to the lower-level
    `executeCommandStream` to actually inspect *why* it failed) --
    deliberately not unconditional, so a host with its own working,
    possibly non-English locale is never needlessly overridden.
- `MoshOCB` implements AES-128 in OCB mode (RFC 7253) from the RFC's own
  pseudocode, built on CommonCrypto's raw AES-128 ECB single-block
  encrypt/decrypt as the "ENCIPHER"/"DECIPHER" primitive. CryptoKit has no
  OCB implementation, but CryptoSwift has shipped one since v1.3.3 --
  **this was written from the RFC by choice, not necessity**: implementing
  a cipher mode from its own spec is a more interesting problem than
  adding a dependency for it. Mosh's wire protocol does fix the
  construction itself (AES-128, 12-byte nonce, 128-bit tag, no associated
  data) to interoperate with a real, unmodified `mosh-server` -- that part
  isn't negotiable the way TLS cipher suites are -- but which
  implementation satisfies it was a preference, not a constraint.
  It's validated in `MoshOCBTests` against all 16 of RFC 7253 Appendix A's
  published test vectors (parsed programmatically out of the RFC text
  during development, not hand-transcribed, since a single mistyped hex
  digit in a 100+ character string would be exactly the kind of error
  these vectors exist to catch). If you ever touch this file, rerun those
  tests before trusting any change -- a subtly wrong OCB implementation
  doesn't fail loudly, it just fails to interoperate or, worse, silently
  weakens the authentication tag.
- `MoshSession` wraps `MoshOCB` with mosh's own nonce and packet framing
  (confirmed against mosh's `src/crypto/crypto.cc` and `src/network/network.cc`
  upstream, not reconstructed from memory): each UDP datagram is an 8-byte
  big-endian value (top bit = direction, remaining 63 bits = a per-direction
  sequence number that must never repeat under a given key) followed by the
  OCB ciphertext of a 4-byte timestamp/timestamp-reply header plus payload,
  with a 16-byte tag appended. The 12-byte OCB nonce is that same 8-byte
  value left-padded with 4 zero bytes -- it is not sent separately on the
  wire.
- `MoshSessionKey` implements mosh's 22-character printable session-key
  format (`Crypto::Base64Key` in `crypto.cc`): standard base64 of the raw
  16-byte key with the guaranteed trailing `==` stripped, plus the same
  round-trip canonicalization check mosh's own constructor does.
- `MoshCompression` wraps the system **zlib** (`compress`/`uncompress`,
  RFC 1950 format) via `BridgingHeader.h` (`#import <zlib.h>`,
  `SWIFT_OBJC_BRIDGING_HEADER` in `project.yml`, `libz.tbd` linked as an
  SDK dependency). Mosh's wire format always zlib-compresses a serialized
  `Instruction` before fragmenting it -- **Apple's `Compression.framework`
  is not a substitute here**: its `COMPRESSION_ZLIB` algorithm is raw
  DEFLATE without the zlib header/Adler-32 wrapper a real `mosh-server`
  expects, so it silently fails to interoperate rather than erroring
  loudly. `MoshCompressionTests` checks output byte-for-byte against a
  reference blob produced by Python's `zlib.compress` (the same
  underlying library, different binding) -- rerun it if you ever touch
  this file. Because `compress`/`uncompress` share names with this file's
  own wrapper methods, calls into the C functions are qualified as
  `zlib.compress`/`zlib.uncompress`; dropping that qualification compiles
  but silently recurses into the Swift wrapper instead.
- `MoshProtobuf` is a minimal hand-rolled protobuf (proto2 wire format
  only -- varint and length-delimited fields, no fixed32/64) reader/writer.
  A full protobuf runtime would be a much bigger dependency than mosh's
  three tiny fixed-shape messages warrant. `MoshMessages.swift` builds
  `TransportBuffers.Instruction`, `ClientBuffers.UserMessage`, and
  `HostBuffers.HostMessage` on top of it, matching the real `.proto`
  schemas fetched from `mobile-shell/mosh` (not guessed). One nonobvious
  choice: the writer omits any varint field whose value is `0` and any
  bytes field that's empty, rather than always emitting them. This looks
  like it diverges from what protoc's C++ would emit for an *explicitly*
  `set_foo(0)` field -- but every reader here, including mosh's own
  (`networktransport-impl.h`'s `recv()`), only ever calls the plain
  accessor (`inst.old_num()`), never `has_old_num()`, and proto2 scalar
  accessors return the same default whether a field was omitted or
  explicitly zero. The two encodings are indistinguishable to every
  consumer that matters, so don't "fix" this into always emitting --
  it's an intentional size optimization, not a bug.
- `MoshFragment`/`MoshFragmentAssembly`/`MoshFragmenter` mirror mosh's
  `Network::Fragment`/`FragmentAssembly`/`Fragmenter`
  (`src/network/transportfragment.cc`) exactly: an 8-byte big-endian
  fragment-set id plus a 2-byte fragment number (top bit = final) prefixes
  each piece of a zlib-compressed, then possibly split, `Instruction`.
- `MoshTransport` is the actual UDP client: an `NWConnection` wrapping all
  of the above, plus the keystroke/terminal-output state-sync application
  protocol on top. **This has successfully exchanged a real interactive
  shell session with an unmodified `mosh-server`** -- login prompt,
  `echo` command, echoed output, all correctly decrypted, decompressed,
  reassembled, and parsed. See its doc comment for the specific,
  deliberate ways it simplifies mosh's real sender/receiver (no
  pipelining, no adaptive RTT/congestion control, no roaming) -- none of
  which affect wire compatibility, only efficiency/robustness under loss
  or high latency.

### The append-only insight that made the client side tractable

Mosh's actual "instant diff" complexity -- the terminal-frame-aware state
sync that's most of the upstream C++ client's real difficulty -- lives
entirely in `mosh-server`'s own `Terminal::Complete`/`completeterminal.cc`,
which this app never needs to reimplement. Confirmed by reading mosh's own
`src/statesync/user.cc`: `UserStream` (the client's outgoing keystroke/resize
state) is a plain append-only deque, and `HostBytes.hoststring` (the
server's outgoing diff payload) is literal terminal output bytes, not a
structured screen diff. That means `MoshTransport` can feed `hostbytes`
straight into a terminal view exactly like `SSHConnection.onOutput`
already does, with no parallel terminal model to maintain on the client
side -- confirmed by the real Docker session above rendering correctly.

This isn't quite the whole story, though -- see the next section. "Literal
bytes, no structured diff" is true of any *one* instruction's payload, but
it doesn't mean every accepted instruction's payload is safe to feed
verbatim: the real server can (and does) send more than one instruction
whose payload describes the *same* underlying content.

### A real bug this surfaced, worth not reintroducing

The first working version tracked only a single "current position" for
the host stream and rejected any incoming `Instruction` whose `old_num`
didn't match it exactly. Against a real `mosh-server`, this silently
dropped genuine terminal output: mosh's sender pipelines by design (its
`assumed_receiver_state` only optimistically advances once enough time
has passed to assume an earlier send was received), so a burst of host
output right after connecting produced two sibling states both anchored
on the same reference (`old_num=1`) -- one with an empty diff, one
carrying the actual login banner and prompt. Once the client accepted the
empty sibling and advanced past `old_num=1`, the real content's sibling
was permanently rejected as "already past this reference." The fix,
`MoshTransport.recentBaselines`, retains a small bounded window of
recently-superseded reference numbers as still-valid `old_num` anchors,
rather than only the single latest. If you ever "simplify" the receiver
back to single-position tracking, expect exactly this failure mode:
sessions that connect but the initial prompt or a burst of output goes
missing, non-deterministically, depending on timing.

### A second real bug this surfaced: identical siblings duplicate output

The `recentBaselines` fix above (accepting siblings, not just the single
latest position) fixed content being *dropped*, but uncovered a second,
opposite bug once a real interactive command was sent over a wired-up
session: content getting *duplicated*. Verified against a real
`mosh-server`: its tick loop can resend "the current diff" under a fresh
`new_num` even when nothing new has happened server-side (it doesn't
wait for an ack before ticking again), and since that diff is computed
fresh each tick from the same still-unacknowledged reference, two
successive ticks can carry byte-for-byte *identical* `hostbytes` content
under two different, both-valid `new_num`s. `recentBaselines` alone
correctly accepts both (they're both real, both anchored on a baseline
the client has genuinely seen) -- but naively feeding each accepted
instruction's `hostbytes` straight to the terminal, as the "append-only"
section above suggested was sufficient, then renders that identical
content twice (observed directly: a test command's echoed output and
prompt appeared twice in the live terminal).

The fix, `MoshTransport.contentFedForBaseline`, tracks what's already
been fed for each retained baseline (`old_num`) and only feeds the part
of a newly-accepted instruction's content that extends *beyond* what was
already fed from that same baseline -- an identical resend then feeds
nothing further, and a genuinely longer sibling only feeds its new tail.
If you ever "simplify" this back to "just feed every accepted
instruction's hostbytes," expect exactly this failure mode: commands and
their output visibly repeating in the terminal, depending on server
timing you don't control.

### Predictive local echo (`MoshPredictionEngine`)

Real mosh's `Overlay::PredictionEngine` (`src/frontend/terminaloverlay.cc`)
maintains its own full mirrored terminal framebuffer and overlays
predicted cells onto it with epoch tracking, glitch detection, and
SRTT-adaptive show/hide -- because it needs to reconcile predictions
against a real terminal-frame model it already maintains for other
reasons. This app deliberately has no such parallel model (see "The
append-only insight" above), so `MoshPredictionEngine` takes a completely
different approach: it predicts by drawing an underlined preview
character and then moving the cursor *back* to exactly where it started
(`\x1b[4m<char>\x1b[24m` followed by a relative cursor-left move), so the
terminal's own real cursor position never actually advances until a real,
confirmed byte arrives and naturally overwrites the same cell. That
means confirmation needs no special handling: real bytes are never
suppressed, delayed, or rewritten by this engine, only observed
(`reconcile(hostBytes:)`) to track which predictions have been confirmed.

This was verified against a real SwiftTerm `Terminal` (not just unit
tests of the byte-generation logic in isolation): feeding a prediction's
output left the cursor exactly where it started while the predicted text
was already visible, and feeding the real confirming bytes afterward
advanced the cursor by exactly the right amount with the final text
containing no duplication. If you ever change the cursor-movement math in
`predict(keystroke:)`, re-verify this the same way (a headless
`SwiftTerm.Terminal` with a stub delegate, checking `buffer.x` and
`getBufferAsData()`) -- a subtly wrong offset is exactly the kind of bug
that looks fine in a unit test of the raw bytes but visibly desyncs the
display against a real terminal.

Deliberate simplifications, all in the direction of "never wrong,
sometimes less helpful" rather than mosh's more complete but far more
involved approach: only single plain printable ASCII keystrokes are
predicted (not Enter, Backspace, arrow keys, or paste/batched input); any
sign of trouble (a mismatched confirmation, or a control/escape byte
arriving mid-prediction) abandons the whole pending queue at once rather
than attempting partial reconciliation. `TerminalSessionController` also
gates prediction off entirely while
`view.getTerminal().isCurrentBufferAlternate` is true (vim, htop, less,
etc.), and resets the pending queue on resize.

**A real bug this surfaced in production, not just a rare edge case as
first assumed**: running Claude Code's own CLI (`claude`) over a Mosh
session produced glitchy output and stray underlined blank cells
(rendering as spurious underscores) left under the input line. Raw-mode,
self-redrawing programs like that don't echo typed characters
sequentially in place the way a plain shell does -- they redraw their own
input box using absolute cursor positioning, so *most* of their
predictions get abandoned before a real byte ever lands on the exact cell
a prediction occupies. The original design assumed abandonment was rare
enough that leaving a stray prediction on screen "until something else
overwrites that cell" was an acceptable cosmetic limitation; against a
program that abandons predictions constantly, that stale cell often never
gets overwritten at all, making the artifact permanent and the constant
predict/abandon cycle itself visibly glitchy. Two fixes, both verified
against a real SwiftTerm `Terminal` reproducing exactly this scenario (a
program that redraws with absolute positioning instead of echoing
in place):
1. Abandoning a prediction -- for any reason, in both `predict` and
   `reconcile` -- now returns an explicit erase instruction
   (`CSI <n> X`, Erase Character: blanks `n` cells at the cursor without
   moving it) instead of just forgetting about the prediction, so a stale
   underline can never linger past the moment it's known to be wrong.
   `TerminalSessionController` feeds this cleanup *before* the real bytes
   that triggered it.
2. `mispredictionCount`/`isDisabled`: a genuine misprediction (a real byte
   that contradicts an actively pending prediction) is tracked separately
   from simply declining to predict an unpredictable keystroke (Enter,
   Backspace, arrows are normal and expected, not evidence of a problem --
   only counting *actual* mismatches avoids tripping this on completely
   ordinary shell usage, which was confirmed with a dedicated test). After
   `mispredictionCircuitBreakerThreshold` (3) genuine mismatches, this
   engine stops predicting for the rest of its lifetime -- one
   `MoshPredictionEngine` lives as long as its `TerminalSessionController`,
   i.e. the whole terminal session including any Mosh roaming reconnects --
   rather than continuing to flicker predictions on and off against a
   program it's already shown it can't keep up with.

If you ever "simplify" either of these back out, expect exactly this
failure mode to return: run something that doesn't do simple sequential
echo (a TUI, a fancy prompt, another CLI agent) over a Mosh session and
watch for stray underlined cells or flicker.

### Roaming (`MoshTransport`'s `NWPathMonitor` + rebuild logic)

Confirmed by reading mosh's own `network.cc` that address roaming is
entirely server-side: a real `mosh-server` just accepts a new client
address the instant a packet from it decrypts correctly ("only client
can roam" is a guard against the *server* wandering, not something that
gates the client). So the client's whole job is surviving its own local
network changing without restarting the session. Three independent
triggers all funnel into the same `rebuildConnection()`, which tears down
and recreates the underlying `NWConnection` to the same host/port while
leaving `session`, sequence counters, and all other application state
completely untouched (never resetting the per-direction sequence
counters across a rebuild is load-bearing -- reusing one under the same
key is exactly the nonce reuse `MoshOCB`'s doc comment says is
catastrophic):
1. `NWPathMonitor` reporting a materially different local path (changed
   available interfaces) than the one last known.
2. The `NWConnection`'s own state turning `.failed`.
3. A silence timeout: **UDP has no delivery/ack signal at the socket
   layer**, so a plain packet blackhole (a NAT mapping expiring, moving
   out of Wi-Fi range) doesn't necessarily surface as a connection error
   at all -- `send` can keep "succeeding" into the void. `lastReceivedAt`
   tracks the last authenticated packet and the heartbeat tick
   proactively rebuilds if that's gone quiet for `silenceRebuildThreshold`
   (12s), mirroring why mosh's own client tracks "server late"/"reply
   late" as a concept separate from outright connection errors.

A capped `consecutiveRebuildFailures` (reset on any successful receive,
not just once at connect time) stops automatic retries and reports a
hard failure via `onError` after 5 back-to-back failed rebuilds, so a
genuinely dead network doesn't retry forever silently.

Verified against a real `mosh-server`: blocked UDP traffic to the
session's port inside the Docker container via `iptables -A INPUT -p udp
--dport <port> -j DROP` for ~15 seconds (comfortably past the silence
threshold), confirmed no output arrived during the blackout, removed the
rule, and confirmed the session resumed -- including delivering the
output of a command sent *during* the blackout -- without any
re-bootstrap over SSH. A genuine Wi-Fi-to-cellular interface handoff on a
physical device hasn't been exercised, only this induced-blackhole
scenario and `NWPathMonitor`'s own reported path changes.

### A real bug this surfaced: `onError` firing repeatedly caused a
### reconnect storm

Reported directly: auto-reconnect on a dropped Mosh session "crashed
spawning dozens of attempted reconnections and upgrading them all to
mosh at once, then reconnecting the ssh connection we dropped for mosh."
The root cause was `onError` firing *repeatedly* rather than once,
compounding through three separate layers with no de-duplication at any
of them:

1. **`MoshTransport`**: `consecutiveRebuildFailures` grew unboundedly and
   was never capped/reset after first exceeding the threshold, so
   `rebuildConnection` re-reported `roamingGaveUp` via `onError` on
   *every* subsequent rebuild attempt -- roughly every 3-12s, forever,
   for as long as the network stayed down. Several other internal paths
   (a send completion error, a fragmenter error, a protocol-version
   mismatch) could also call `onError` directly, with nothing preventing
   any of them from firing more than once either.
2. **`SSHConnection.attemptMoshUpgrade`'s post-commit `onError` handler**
   had no guard against being invoked more than once -- each firing
   unconditionally spawned a fresh `finishWithDrop`/`onDrop` cycle.
3. **`SessionManager`'s `onDrop` -> `reconnectWithBackoff`**: each
   `onDrop` firing scheduled a *new* backoff `Task` without cancelling
   any previous one still waiting out its delay, so repeated firings
   left multiple independent backoff timers running concurrently, each
   eventually calling `connect()` on its own schedule.
4. **`SSHConnection.connect()`'s re-entrancy guard** was
   `network.client == nil` -- but `network.client` isn't set until deep
   inside the asynchronously-running SSH handshake inside `runSession`,
   so several `connect()` calls landing within that window (exactly what
   #3 produced) could all observe it as still nil and each spawn their
   *own* independent `runSession`: a real second (third, fourth, ...) SSH
   connection, each attempting its own Mosh upgrade concurrently. Some of
   those concurrent attempts fail their own upgrade and fall through to
   the plain SSH PTY path instead, all racing to feed the same
   `onOutput` -- which is what "reconnecting the ssh connection we
   dropped for mosh" looked like from the outside.

Fixed at every layer rather than just the first one, since each is a
real, independent bug worth not reintroducing on its own:
1. `MoshTransport.hasReportedFatalError`/`reportFatalError(_:)`: `onError`
   fires at most once per transport instance, from any call site.
   `rebuildConnection` also checks this flag and stops rebuilding once
   it's set, rather than continuing to churn a transport its owner is
   about to tear down anyway. Verified with a direct unit test
   (`MoshTransportTests`) and, more importantly, a real ~90-second
   induced blackout against a live `mosh-server` sampling the fire count
   over time: it settled at exactly 1 and never grew further, where the
   old code would have kept incrementing roughly every 3s throughout.
2. `reconnectWithBackoff` now cancels any existing pending `reconnectTask`
   before scheduling a new one.
3. `SSHConnection.connect()`'s re-entrancy guard is now `connectTask ==
   nil` instead of `network.client == nil` -- `connectTask` is set
   synchronously within `connect()` itself (nothing awaited between the
   guard check and the set), so on this `@MainActor`-isolated class no
   other call to `connect()` can interleave and slip through, regardless
   of how long the underlying handshake takes. `connectTask` is now
   cleared in `finishCleanly`/`finishWithDrop` (not just `disconnect()`),
   since it represents "a session is active" for the connection's *entire*
   lifetime now, not just the initial handshake -- see its updated doc
   comment.

If you ever "simplify" any one of these back out on the theory that the
others already cover it, expect this exact failure mode to return under
different specific timing: a single dropped Mosh session spawning
multiple real, concurrent SSH connections.

### A fourth real bug: `disconnect()` didn't reach the in-flight Mosh
### upgrade attempt

`SSHConnection.attemptMoshUpgrade` runs as `moshTask`, a plain `Task { }`
created inside `runSession` -- **not** a structured child of `connectTask`.
Cancelling `connectTask` (what `disconnect()` does) does not cancel an
unstructured sibling `Task { }`, and `attemptMoshUpgrade` never checked
`Task.isCancelled` either. Concretely: `network` (`SSHNetworkState`) is a
single `let`-bound instance for the connection's entire lifetime, not
recreated per attempt. If the user disconnected while the Mosh
bootstrap/UDP-confirm handshake was still in flight (up to the 2s
`moshConfirmationTimeout`), that handshake could still resolve
successfully afterward and run its "commit to Mosh" tail --
`network.moshTransport = transport` -- writing into the very same
`SSHNetworkState` instance `disconnect()` had just nilled out. The session
the user explicitly closed would silently come back as `.connected`, with
a live `MoshTransport`/`NWConnection` nothing else knew to tear down. Fix:
`attemptMoshUpgrade` now checks `await MainActor.run { self.userInitiatedClose }`
immediately after the handshake succeeds and before touching `network` or
`self.state` -- if the user disconnected meanwhile, it calls
`transport.stop()` and bails out instead of committing. If you ever plumb
real `Task` cancellation through this path instead, keep this check (or
its equivalent) rather than removing it once cancellation "should" cover
it -- unstructured tasks don't inherit cancellation automatically, so
nothing else in this codebase currently guarantees that a torn-down
`network` stays torn down against a late-resolving concurrent attempt.

A related, narrower gap in the same area: `finishWithDrop` used to
unconditionally overwrite `self.state = newState`, gating only `onDrop`
behind `!userInitiatedClose`. A drop that resolves *after* the user's own
`disconnect()` already set `.disconnected` (e.g. a send-completion error
racing `MoshTransport.stop()`/`client.close()`) could flash a misleading
`.failed(...)` error for a close the user explicitly asked for. `state` is
now gated the same way `onDrop` already was.

### A fifth real bug: `MoshTransport.stop()` bypassed its own serial queue

Every mutator of `MoshTransport`'s `connection`/`pathMonitor`/
`heartbeatTimer`/`isStopped` (`rebuildConnection`, `armConnection`'s
handler, `send`, `resize`, the heartbeat and path-monitor callbacks) runs
on the private `queue` -- except `stop()` used to mutate all of them
directly from the caller's own thread. Since `stop()` is called from
`SSHConnection` (main actor or its detached task), not from a closure
already running on `queue`, this was a genuine unsynchronized race: a
`disconnect()` landing mid-roam could race `stop()`'s `connection.cancel()`
against `rebuildConnection`'s `connection = NWConnection(...)` reassigning
the same reference-typed `var` concurrently. `@unchecked Sendable` on the
type silences the compiler here but was never a guarantee this code path
was actually race-free. Fixed by routing `stop()`'s body through
`queue.sync { ... }` like every sibling mutator -- safe because `stop()`
is never called from within `queue` itself (verified: no call site inside
`MoshTransport.swift`).

### A sixth real bug: two concurrent new-host prompts silently stranded
### one connection forever

`HostKeyStore.pendingConfirmation` was a single stored optional, but
`evaluate(host:fingerprint:)` can be entered concurrently by more than one
in-flight `connect()` -- e.g. two never-before-seen hosts opened within
the same second. The second call's confirmation unconditionally
overwrote the first's `pendingConfirmation`, discarding the only
reference to the first call's `CheckedContinuation`: that connection
hung in `.connecting` forever, no error, no timeout, recoverable only by
force-quitting the app. Separately, the confirmation sheet
(`sssshApp.swift`) had no `.interactiveDismissDisabled()`, so swiping it
away (instead of tapping Trust/Cancel) set `pendingConfirmation` back to
`nil` without ever calling `pending.decide`, orphaning that continuation
the same way. Fixed both: `HostKeyStore.confirmationQueue` now queues
additional confirmations instead of overwriting `pendingConfirmation`,
presenting them one at a time as each is decided
(`presentNextConfirmationIfNeeded`), and the sheet now has
`.interactiveDismissDisabled()` so a host-key trust decision can only be
made explicitly. If you ever go back to a bare `pendingConfirmation`
optional or drop the dismiss guard, expect exactly this: a second new
host connected in quick succession (or a swiped-away dialog) leaves a
connection stuck "Connecting…" with no way to recover short of
relaunching.

### Hardening the wire-format parsers against a hostile `mosh-server`

Three small crash-safety gaps, all in the same family: this app trusts
that a `mosh-server` holding a valid session key won't send a
maliciously-crafted plaintext, but a compromised or simply buggy server
can, and none of these needed to defeat OCB authentication first -- the
legitimate key-holder can already craft the plaintext.
- `MoshTransport.handleIncoming` did `serverAckedCount = max(serverAckedCount,
  instruction.ackNum)` with `instruction.ackNum` an unvalidated `UInt64`
  from the server. `sendState()` then does
  `sentEvents[Int(oldNum)...]` where `oldNum` is that same value --
  a bogus `ackNum` above `sentEvents.count` (trivially true right after
  connect, when `sentEvents` is still empty) crashes with an
  out-of-range trap; a value above `Int.max` crashes the `Int(oldNum)`
  conversion itself. Now clamped: `min(max(serverAckedCount,
  instruction.ackNum), UInt64(sentEvents.count))` -- `ackNum` can never
  legitimately exceed how many events were actually sent, so this isn't
  just a safety net, it's the mathematically correct bound regardless of
  trust.
- `MoshProtobuf.parseFields`'s length-delimited field case converted an
  attacker-controlled varint `length` straight to `Int` before bounds-
  checking it (`i + Int(length) <= data.count`) -- `Int(length)` itself
  traps for any value above `Int.max`. Fixed by comparing `length` against
  the remaining byte count as `UInt64` first, only converting to `Int`
  once it's known to fit.
- `MoshFragmentAssembly.addFragment` could have `fragmentsArrived` exceed
  `fragmentsTotal` if a fragment index at or beyond an already-established
  final index arrived (this app's own `MoshFragmenter` never produces
  that ordering, but a hostile sender isn't bound by it) -- once
  `arrived > total`, that fragment-set id could never complete, wedging
  reassembly until a fragment with a new id reset state. Now such a
  fragment is dropped instead of counted, leaving the id still able to
  complete normally from its genuinely missing lower-index fragments.

If you touch any of these three, re-run `MoshTransportTests`/
`MoshFragmentTests` and specifically think about what an adversarial
(not just malformed) value in that field could do, not just what a real
`mosh-server` would ever actually send.

### Still open

- Hardening `MoshTransport`'s remaining simplifications (no send
  pipelining, no SRTT-based retransmission timing) for real lossy/
  high-latency links -- see its doc comment. All verification so far is
  over a clean localhost Docker path.
- `SSHConnection.attemptMoshUpgrade`'s 5-second confirmation window, the
  3-second heartbeat interval, and roaming's 12-second silence threshold
  are all fixed constants, not tuned against anything real -- fine for a
  local/low-latency path, untested for whether they're well-chosen on a
  slow/high-latency link.

### Verifying against a real `mosh-server`

The Docker container described below in "Manual verification against a
real SSH server" is `lscr.io/linuxserver/openssh-server`, which is
**Alpine-based** -- install mosh with `apk add --no-cache mosh` (not
`apt-get`), and publish a small explicit UDP port range
(`-p 60000-60010:60000-60010/udp` when running the container) so
`mosh-server`'s default port picking (starting at 60001) has somewhere to
bind that's actually reachable from the host. A full round-trip check
(bootstrap over SSH, open `MoshTransport`, send a command, see its output)
needs a real `NWConnection`, which only works from a macOS/iOS process --
verified here the same way CLAUDE.md's SSH section recommends for
Process/NSTask: a standalone macOS SwiftPM executable importing the same
Mosh sources and Citadel, not an iOS Simulator XCTest.

## TestFlight release notes

`ci_scripts/ci_pre_xcodebuild.sh` writes a freshly generated three-line
haiku to `TestFlight/WhatToTest.en-US.txt` before every Xcode Cloud
build (gated on `CI_BUILD_NUMBER` like `ci_post_clone.sh`, so it's a
no-op locally). `ci_scripts/generate_whattotest.py` is the generator --
a 3-state automaton, one state per line, each drawing a random phrase
from its own hand-counted 5/7/5-syllable bank. Phrases are templated
rather than composed word-by-word because programmatic English syllable
counting is unreliable; correctness instead comes from every phrase in
the bank being counted by hand. Run it directly to preview output:
`python3 ci_scripts/generate_whattotest.py`.

This relies on Xcode Cloud's documented convention of auto-reading
`TestFlight/WhatToTest.<locale>.txt` from the repository at archive time
and using it as that build's TestFlight "What to Test" notes, with no
App Store Connect API call (and no credentials) required. That
convention hasn't been confirmed against a real Xcode Cloud run yet --
if a build ships without the haiku showing up in TestFlight, check
Apple's current docs for the exact expected filename/path before
assuming the generator itself is at fault.

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
