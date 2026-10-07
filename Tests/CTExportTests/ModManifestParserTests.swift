import XCTest
@testable import CTExport

final class ModManifestParserTests: XCTestCase {
    private let infoText = """
    !comment
    Name=Default Name
    Name-fr=French Name
    Name-fr-CA=Quebec Name
    Description=Default Description
    """

    /// "Crate Manifest Localization", most-specific match wins
    /// (`fr-CA` over the bare `fr` fallback).
    func testMostSpecificLocaleMatchWins() {
        let manifest = ModManifestParser.parseInfo(infoText, settingsText: nil, layerIndices: [], hasIcon: false, locale: Locale(identifier: "fr-CA"))
        XCTAssertEqual(manifest.name, "Quebec Name")
    }

    /// A locale with no exact regional variant falls back to the bare
    /// language variant (`fr-FR` -> `Name-fr`, since no `Name-fr-FR` key
    /// exists in this manifest).
    func testFallsBackToBareLanguageVariant() {
        let manifest = ModManifestParser.parseInfo(infoText, settingsText: nil, layerIndices: [], hasIcon: false, locale: Locale(identifier: "fr-FR"))
        XCTAssertEqual(manifest.name, "French Name")
    }

    /// A locale with no matching variant at all falls back to the base
    /// (unsuffixed) key.
    func testFallsBackToBaseKeyWhenNoLocalizedVariantExists() {
        let manifest = ModManifestParser.parseInfo(infoText, settingsText: nil, layerIndices: [], hasIcon: false, locale: Locale(identifier: "en-US"))
        XCTAssertEqual(manifest.name, "Default Name")
        XCTAssertEqual(manifest.description, "Default Description")
    }
}
