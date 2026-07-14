import Testing
@testable import ssssh

struct TerminalThemeTests {
    @Test func displayNamesAreHumanReadable() {
        #expect(TerminalTheme.crtGreen.displayName == "Green CRT")
        #expect(TerminalTheme.amber.displayName == "Amber CRT")
        #expect(TerminalTheme.highContrast.displayName == "High Contrast")
    }

    @Test func onlyThePhosphorThemesShowScanlines() {
        #expect(TerminalTheme.crtGreen.showsScanlines)
        #expect(TerminalTheme.amber.showsScanlines)
        #expect(!TerminalTheme.highContrast.showsScanlines)
    }

    // The accent color deliberately diverges from the terminal's own
    // foreground color for high contrast (see the doc comment on
    // `accentColor`) -- worth pinning down explicitly since it's easy to
    // "simplify" back to just reusing `foreground` everywhere.
    @Test func highContrastAccentColorDivergesFromForeground() {
        #expect(TerminalTheme.crtGreen.accentColor == TerminalTheme.crtGreen.foreground)
        #expect(TerminalTheme.amber.accentColor == TerminalTheme.amber.foreground)
        #expect(TerminalTheme.highContrast.accentColor != TerminalTheme.highContrast.foreground)
    }

    @Test func allCasesAreCoveredByCaseIterable() {
        #expect(TerminalTheme.allCases.count == 3)
    }
}
