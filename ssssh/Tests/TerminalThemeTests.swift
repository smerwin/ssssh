import Testing
import SwiftUI
import UIKit
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

    @Test func resolvingFallsBackToTheDefaultForAnUnknownStoredValue() {
        #expect(TerminalTheme.resolved(rawValue: "amber", increasedContrast: false) == .amber)
        #expect(TerminalTheme.resolved(rawValue: "notATheme", increasedContrast: false) == .crtGreen)
    }

    /// The accessibility override: a user who's turned on Increase Contrast
    /// system-wide gets High Contrast here no matter what the picker says.
    @Test func increasedContrastOverridesTheStoredTheme() {
        #expect(TerminalTheme.resolved(rawValue: "amber", increasedContrast: true) == .highContrast)
        #expect(TerminalTheme.resolved(rawValue: "crtGreen", increasedContrast: true) == .highContrast)
    }
}

/// Covers `TerminalFontSize`, which shares `TerminalTheme.swift` with the
/// theme model (both are "how the terminal looks" settings).
struct TerminalFontSizeTests {
    @Test func clampingKeepsSizesWithinTheSupportedRange() {
        #expect(TerminalFontSize.clamped(0) == TerminalFontSize.minimum)
        #expect(TerminalFontSize.clamped(-5) == TerminalFontSize.minimum)
        #expect(TerminalFontSize.clamped(1_000) == TerminalFontSize.maximum)
        #expect(TerminalFontSize.clamped(16) == 16)
    }

    /// A pinch produces a continuous scale, so every size on its way to the
    /// terminal (and to `UserDefaults`) gets snapped -- otherwise something
    /// like 17.328125 pt would be what got persisted.
    @Test func snappingRoundsToTheHalfPointStep() {
        #expect(TerminalFontSize.snapped(17.328125) == 17.5)
        #expect(TerminalFontSize.snapped(17.1) == 17)
        #expect(TerminalFontSize.snapped(13.75) == 14)
        // Still clamped: snapping is the only entry point the pinch uses.
        #expect(TerminalFontSize.snapped(0.4) == TerminalFontSize.minimum)
        #expect(TerminalFontSize.snapped(9_999) == TerminalFontSize.maximum)
    }

    @Test func descriptionsCarryTheUnitAndDropAMeaninglessDecimal() {
        #expect(TerminalFontSize.description(of: 14) == "14 pt")
        #expect(TerminalFontSize.description(of: 13.5) == "13.5 pt")
    }

    @Test func theDefaultSizeIsInsideTheAdjustableRange() {
        #expect(TerminalFontSize.standard >= TerminalFontSize.minimum)
        #expect(TerminalFontSize.standard <= TerminalFontSize.maximum)
    }
}

@MainActor
struct TerminalFontScalingTests {
    /// The user's base size and the system text size compose rather than
    /// override each other -- the whole point of keeping Dynamic Type in the
    /// path once the size became adjustable.
    @Test func systemTextSizeScalesOnTopOfTheChosenBaseSize() {
        let base = TerminalFontSize.scaledSize(baseSize: 14, contentSizeCategory: .large)
        let larger = TerminalFontSize.scaledSize(baseSize: 14, contentSizeCategory: .accessibilityExtraExtraExtraLarge)
        let smaller = TerminalFontSize.scaledSize(baseSize: 14, contentSizeCategory: .extraSmall)

        #expect(larger > base)
        #expect(smaller < base)
    }

    /// `.large` is the system's own default category, so a user who's never
    /// touched the system text size sees exactly the size the slider shows.
    @Test func theDefaultContentSizeCategoryLeavesTheBaseSizeAlone() {
        #expect(abs(TerminalFontSize.scaledSize(baseSize: 14, contentSizeCategory: .large) - 14) < 0.001)
    }

    @Test func scaledSizesAreClampedBeforeScaling() {
        let scaled = TerminalFontSize.scaledSize(baseSize: 1_000, contentSizeCategory: .large)
        #expect(abs(scaled - TerminalFontSize.maximum) < 0.001)
    }

    @Test func theTerminalFontIsMonospacedAtTheScaledSize() {
        let font = TerminalFontSize.scaledFont(baseSize: 20, contentSizeCategory: .large)
        #expect(font.pointSize == CGFloat(TerminalFontSize.scaledSize(baseSize: 20, contentSizeCategory: .large)))
        // A terminal rendered in a proportional font would be unusable, so
        // pin down that this isn't just the plain system font at that size.
        #expect(font != UIFont.systemFont(ofSize: font.pointSize))
    }

    /// Scaling is driven off SwiftUI's `DynamicTypeSize` rather than a
    /// `UIView`'s own trait collection (whose propagation timing this app
    /// doesn't control), so the mapping between the two is load-bearing.
    @Test func dynamicTypeSizesMapOntoTheMatchingContentSizeCategories() {
        #expect(DynamicTypeSize.large.uiContentSizeCategory == .large)
        #expect(DynamicTypeSize.xSmall.uiContentSizeCategory == .extraSmall)
        #expect(DynamicTypeSize.accessibility5.uiContentSizeCategory == .accessibilityExtraExtraExtraLarge)
    }
}
