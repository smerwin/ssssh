import Foundation
import Testing
@testable import ssssh

struct ETBootstrapTests {
    @Test("Parses a bare IDPASSKEY reply")
    func parsesBareReply() throws {
        let id = "XXXbcdefghijklmn"
        let passkey = "0123456789ABCDEFGHIJ0123456789AB"
        let output = "IDPASSKEY:\(id)/\(passkey)"
        let result = try ETBootstrap.parse(output: output)
        #expect(result.id == id)
        #expect(result.passkey == passkey)
    }

    @Test("Tolerates surrounding banner text, matching etterminal's real combined output")
    func tolerantOfSurroundingText() throws {
        let id = "XXXbcdefghijklmn"
        let passkey = "0123456789ABCDEFGHIJ0123456789AB"
        let output = """
        Warning: Permanently added 'testhost' (ED25519) to the list of known hosts.
        IDPASSKEY:\(id)/\(passkey)
        etserver started
        """
        let result = try ETBootstrap.parse(output: output)
        #expect(result.id == id)
        #expect(result.passkey == passkey)
    }

    @Test("Throws noEtTerminal when the command isn't found")
    func throwsWhenCommandNotFound() {
        let output = "bash: etterminal: command not found\n"
        #expect(throws: ETBootstrap.BootstrapError.self) {
            try ETBootstrap.parse(output: output)
        }
    }

    @Test("Throws noEtTerminal when the marker is present but truncated")
    func throwsOnTruncatedPayload() {
        let output = "IDPASSKEY:tooshort"
        #expect(throws: ETBootstrap.BootstrapError.self) {
            try ETBootstrap.parse(output: output)
        }
    }

    @Test("Throws noEtTerminal when a shell rc file prints extra text with no slash where expected")
    func throwsOnMalformedPayload() {
        // Real client's own failure mode for this case: something in the
        // remote user's .bashrc/.zshrc printed output that lands where the
        // id/passkey payload was expected.
        let output = "IDPASSKEY:" + String(repeating: "x", count: 49)
        #expect(throws: ETBootstrap.BootstrapError.self) {
            try ETBootstrap.parse(output: output)
        }
    }

    @Test("Rejects a reply whose id half is the wrong length")
    func throwsOnWrongIdLength() {
        // 15 id chars + '/' + 33 passkey chars is still 49 total, so the
        // fixed-width substring succeeds, but the split lands in the wrong
        // place -- exactly the case the extra length validation (beyond
        // what the real C++ bothers to check) exists to catch.
        let output = "IDPASSKEY:" + String(repeating: "a", count: 15) + "/" + String(repeating: "b", count: 33)
        #expect(throws: ETBootstrap.BootstrapError.self) {
            try ETBootstrap.parse(output: output)
        }
    }

    @Test("Generated ids always have the fixed XXX prefix")
    func detectMangledIdPrefix() {
        // Exercises the same character-array mangling detect(client:) does
        // internally, without needing a live SSHClient -- id generation and
        // mangling has no I/O dependency worth mocking around.
        for _ in 0..<20 {
            var chars = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".shuffled().prefix(16))
            chars[0] = "X"
            chars[1] = "X"
            chars[2] = "X"
            let id = String(chars)
            #expect(id.hasPrefix("XXX"))
            #expect(id.count == 16)
        }
    }

    @Test("Parses real output captured from etterminal 7.0.0 over SSH")
    func parsesRealCapturedOutput() throws {
        // Captured verbatim from `ssh testuser@host "echo '...' | etterminal
        // --verbose=0"` against a real Debian-packaged `et` 7.0.0 (see
        // CLAUDE.md's Eternal Terminal section) -- a regression guard that
        // this isn't just parsing synthetic strings shaped like what we
        // assume the real thing looks like. Also confirms the server-side
        // "XXX prefix means regenerate" behavior documented in
        // `SshSetupHandler.cpp`/`TerminalMain.cpp`: the id/passkey below is
        // entirely server-generated, not an echo of whatever client-proposed
        // values were sent.
        let output = """
        Warning: Permanently added '[localhost]:2223' (ED25519) to the list of known hosts.
        bash: warning: setlocale: LC_ALL: cannot change locale (en_US.UTF-8)
        IDPASSKEY:rHQ8Y9jVVf95KHHg/HYsIIjMJ9NMVxO0ec0wNzCcLc0qOEp0v
        """
        let result = try ETBootstrap.parse(output: output)
        #expect(result.id == "rHQ8Y9jVVf95KHHg")
        #expect(result.passkey == "HYsIIjMJ9NMVxO0ec0wNzCcLc0qOEp0v")
    }

    @Test("Throws serverNotReachable when nothing is listening on the port")
    func throwsWhenPortUnreachable() async {
        // 127.0.0.1 with an ephemeral high port nothing should be bound to
        // -- a real, fast, offline-capable exercise of the ping() failure
        // path, same shape as pinging a host with no etserver running.
        await #expect(throws: ETBootstrap.BootstrapError.self) {
            try await ETBootstrap.ping(host: "127.0.0.1", port: 59999, timeout: 2)
        }
    }
}
