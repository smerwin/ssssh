import Foundation
import Testing
@testable import ssssh

struct MoshBootstrapTests {
    @Test("Parses a bare MOSH CONNECT line")
    func parsesBareLine() throws {
        let key = MoshSessionKey.printableKey(for: MoshSessionKey.generateRandomForTesting())
        let output = "MOSH CONNECT 60001 \(key)\n"
        let result = try MoshBootstrap.parse(output: output)
        #expect(result.port == 60001)
        #expect(MoshSessionKey.printableKey(for: result.sessionKey) == key)
    }

    @Test("Tolerates a version banner and detached-pid notice around the line")
    func tolerantOfSurroundingBanner() throws {
        let key = MoshSessionKey.printableKey(for: MoshSessionKey.generateRandomForTesting())
        let output = """
        MOSH CONNECT 60123 \(key)

        mosh-server (mosh 1.4.0) [build appleclang]
        Copyright 2012 Keith Winstein <mosh-devel@mit.edu>
        License GPLv3+: GNU GPL version 3 or later <http://gnu.org/licenses/gpl.html>.
        This is free software: you are free to change and redistribute it.
        There is NO WARRANTY, to the extent permitted by law.

        [mosh-server detached, pid = 12345]
        """
        let result = try MoshBootstrap.parse(output: output)
        #expect(result.port == 60123)
        #expect(MoshSessionKey.printableKey(for: result.sessionKey) == key)
    }

    @Test("Tolerates a leading blank line (the isatty bodge mosh-server prints)")
    func tolerantOfLeadingBlankLine() throws {
        let key = MoshSessionKey.printableKey(for: MoshSessionKey.generateRandomForTesting())
        let output = "\r\n\nMOSH CONNECT 60050 \(key)\n"
        let result = try MoshBootstrap.parse(output: output)
        #expect(result.port == 60050)
        #expect(MoshSessionKey.printableKey(for: result.sessionKey) == key)
    }

    @Test("Throws noMoshServer when the command isn't found")
    func throwsWhenCommandNotFound() {
        let output = "bash: mosh-server: command not found\n"
        #expect(throws: MoshBootstrap.BootstrapError.self) {
            try MoshBootstrap.parse(output: output)
        }
    }

    @Test("Throws noMoshServer on a locale failure with no CONNECT line")
    func throwsOnLocaleFailure() {
        let output = """
        mosh-server needs a UTF-8 native locale to run.

        Unfortunately, the local environment (LC_ALL) specifies
        the character set "ANSI_X3.4-1968",
        """
        #expect(throws: MoshBootstrap.BootstrapError.self) {
            try MoshBootstrap.parse(output: output)
        }
    }

    @Test("Throws noMoshServer on a malformed key rather than crashing")
    func throwsOnMalformedKey() {
        let output = "MOSH CONNECT 60001 not-a-valid-key\n"
        #expect(throws: MoshBootstrap.BootstrapError.self) {
            try MoshBootstrap.parse(output: output)
        }
    }

    @Test("Recognizes mosh-server's real UTF-8 locale failure message")
    func recognizesRealLocaleFailureMessage() {
        // Captured verbatim by running `mosh-server new -s` in a
        // deliberately bare (`env -i`) shell environment on macOS -- the
        // exact environment a non-interactive, non-login SSH exec request
        // can produce (see MoshBootstrap.pathPrefix's doc comment).
        let output = """
        Warning: SSH_CONNECTION not found; binding to any interface.
        mosh-server needs a UTF-8 native locale to run.

        Unfortunately, the local environment ([no charset variables]) specifies
        the character set "US-ASCII",

        The client-supplied environment ([no charset variables]) specifies
        the character set "US-ASCII".

        LANG=""
        LC_COLLATE="C"
        LC_CTYPE="C"
        LC_MESSAGES="C"
        LC_MONETARY="C"
        LC_NUMERIC="C"
        LC_TIME="C"
        LC_ALL=
        """
        #expect(MoshBootstrap.needsUTF8LocaleFallback(output))
    }

    @Test("Does not mistake an unrelated failure for the locale one")
    func doesNotMistakeCommandNotFoundForLocaleFailure() {
        #expect(!MoshBootstrap.needsUTF8LocaleFallback("zsh:1: command not found: mosh-server\n"))
    }

    @Test("Parses real output captured from mosh-server 1.4.0 over SSH")
    func parsesRealCapturedOutput() throws {
        // Captured verbatim from `ssh testuser@host "mosh-server new -s"`
        // against a real Alpine `mosh` 1.4.0 package (see CLAUDE.md's Mosh
        // section) -- a regression guard that this isn't just parsing
        // synthetic strings shaped like what we assume the real thing looks
        // like.
        let output = """
        MOSH CONNECT 60001 cN/2XFVlFLAr41WughHGpQ

        mosh-server (mosh 1.4.0) [build mosh 1.4.0]
        Copyright 2012 Keith Winstein <mosh-devel@mit.edu>
        License GPLv3+: GNU GPL version 3 or later <http://gnu.org/licenses/gpl.html>.
        This is free software: you are free to change and redistribute it.
        There is NO WARRANTY, to the extent permitted by law.

        [mosh-server detached, pid = 259]
        """
        let result = try MoshBootstrap.parse(output: output)
        #expect(result.port == 60001)
        #expect(MoshSessionKey.printableKey(for: result.sessionKey) == "cN/2XFVlFLAr41WughHGpQ")
        #expect(result.sessionKey == [0x70, 0xdf, 0xf6, 0x5c, 0x55, 0x65, 0x14, 0xb0, 0x2b, 0xe3, 0x55, 0xae, 0x82, 0x11, 0xc6, 0xa5])
    }
}
