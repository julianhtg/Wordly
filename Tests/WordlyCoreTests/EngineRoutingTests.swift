import XCTest
@testable import WordlyCore

final class EngineRoutingTests: XCTestCase {
    let fast: Set<String> = ["de", "en", "fr", "pl"]

    func testFastEngineOnlyWhenItCoversEverySelectedLanguage() {
        XCTAssertTrue(EngineRouting.prefersFast(languages: ["de"], fast: fast))
        XCTAssertTrue(EngineRouting.prefersFast(languages: ["de", "en"], fast: fast))
        // One language it doesn't know is enough to disqualify it: it has no way
        // to report "not mine", it would just emit confident nonsense.
        XCTAssertFalse(EngineRouting.prefersFast(languages: ["de", "th"], fast: fast))
        // "Auto over all 100" is not something a 30-language model can honour.
        XCTAssertFalse(EngineRouting.prefersFast(languages: [], fast: fast))
    }

    func testPreferenceForcesTheEngine() {
        XCTAssertEqual(EngineRouting.engineName(preference: "whisper", languages: ["de"],
                                                fastLanguages: fast), "whisper")
        XCTAssertEqual(EngineRouting.engineName(preference: "parakeet", languages: ["th"],
                                                fastLanguages: fast), "parakeet")
        XCTAssertEqual(EngineRouting.engineName(preference: "nonsense", languages: ["de"],
                                                fastLanguages: fast), "parakeet")
    }

    func testAutoRoutesByLanguage() {
        XCTAssertEqual(EngineRouting.engineName(preference: "auto", languages: ["de", "en"],
                                                fastLanguages: fast), "parakeet")
        XCTAssertEqual(EngineRouting.engineName(preference: "auto", languages: ["ja"],
                                                fastLanguages: fast), "whisper")
        XCTAssertEqual(EngineRouting.engineName(preference: "auto", languages: [],
                                                fastLanguages: fast), "whisper")
    }

    func testParakeetReportsARealLanguageSet() {
        // Straight from FluidAudio's own table — the routing is only as honest
        // as this set is.
        XCTAssertTrue(ParakeetEngine.supported.contains("de"))
        XCTAssertTrue(ParakeetEngine.supported.contains("uk"))
        XCTAssertFalse(ParakeetEngine.supported.contains("ja"))
        XCTAssertFalse(ParakeetEngine.supported.contains("th"))
    }

    func testFreshInstallSeedsLanguagesFromMacOS() {
        XCTAssertEqual(Config.systemLanguages(["de-DE", "en-DE"]), ["de", "en"])
        XCTAssertEqual(Config.systemLanguages(["en-US", "en-GB", "fr-FR"]), ["en", "fr"])
        // Unknown codes are dropped, and the list is capped at two.
        XCTAssertEqual(Config.systemLanguages(["zz-ZZ", "de-DE"]), ["de"])
        XCTAssertEqual(Config.systemLanguages(["de-DE", "en-US", "fr-FR"]), ["de", "en"])
    }
}
