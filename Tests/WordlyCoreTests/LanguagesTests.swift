import XCTest
@testable import WordlyCore

final class LanguagesTests: XCTestCase {
    func testTableComesFromTheModelAndCoversTheUsualSuspects() {
        // whisper's own table: 100 entries for large-v3 (99 plus Cantonese).
        XCTAssertEqual(Languages.all.count, 100)
        XCTAssertEqual(Languages.name(of: "de"), "German")
        XCTAssertEqual(Languages.name(of: "yue"), "Cantonese")
        XCTAssertNil(Languages.name(of: "klingon"))
        XCTAssertTrue(Languages.isKnown("th"))
    }

    func testEveryCuratedCodeExistsInTheModel() {
        for code in Languages.common {
            XCTAssertTrue(Languages.isKnown(code), "\(code) is not a whisper language")
        }
    }

    func testPicksTheMostLikelyAllowedLanguage() {
        var probabilities = [Float](repeating: 0, count: 100)
        probabilities[id("cy")] = 0.7  // Welsh: a known attractor for German speech
        probabilities[id("de")] = 0.25
        probabilities[id("en")] = 0.05

        // Welsh wins outright, but the user does not speak it — clamping to the
        // selected languages is the whole point.
        XCTAssertEqual(Languages.best(from: probabilities, allowed: ["de", "en"],
                                      primary: "de"), "de")
    }

    func testFallsBackToPrimaryWhenDetectionIsACoinFlip() {
        var probabilities = [Float](repeating: 0, count: 100)
        probabilities[id("nl")] = 0.4
        probabilities[id("de")] = 0.35

        XCTAssertEqual(Languages.best(from: probabilities, allowed: ["nl", "de"],
                                      primary: "de"), "de")
        // Same distribution, but confident enough once the bar is lowered.
        XCTAssertEqual(Languages.best(from: probabilities, allowed: ["nl", "de"],
                                      primary: "de", threshold: 0.3), "nl")
    }

    func testUnknownOrEmptyAllowedListFallsBackInsteadOfCrashing() {
        let probabilities = [Float](repeating: 0.01, count: 100)
        XCTAssertEqual(Languages.best(from: probabilities, allowed: [], primary: "de"), "de")
        XCTAssertEqual(Languages.best(from: probabilities, allowed: ["klingon"],
                                      primary: "de"), "de")
    }

    private func id(_ code: String) -> Int { Int(Languages.id(of: code)) }
}
