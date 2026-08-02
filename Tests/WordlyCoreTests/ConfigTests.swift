import XCTest
@testable import WordlyCore

final class ConfigTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("wordly-test-\(UUID().uuidString)/config.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent())
    }

    /// A fresh install is defaults plus the languages macOS already uses.
    private var freshInstall: Config {
        var config = Config()
        config.languages = Config.systemLanguages()
        return config
    }

    func testMissingFileYieldsDefaultsAndCreatesFile() {
        let c = Config.load(from: tmp)
        XCTAssertEqual(c, freshInstall)
        XCTAssertEqual(c.keyCode, 10)
        XCTAssertEqual(c.languages, Config.systemLanguages())
        XCTAssertFalse(c.cleanupEnabled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.path))
    }

    func testUnconfiguredLanguagesMeanAutoWithAnEnglishFallback() {
        var c = Config()
        XCTAssertEqual(c.languages, [])
        XCTAssertEqual(c.primaryLanguage, "en")
        c.languages = ["pl", "de"]
        XCTAssertEqual(c.primaryLanguage, "pl")
    }

    func testRoundTrip() {
        var c = Config()
        c.cleanupEnabled = true
        c.languages = ["de", "en"]
        c.save(to: tmp)
        XCTAssertEqual(Config.load(from: tmp), c)
        XCTAssertEqual(Config.load(from: tmp).primaryLanguage, "de")
    }

    /// Configs written before 1.2 carry a single "language" key. Upgrading must
    /// keep the user's choice instead of silently resetting it to auto.
    func testMigratesPre12SingleLanguageKey() throws {
        try FileManager.default.createDirectory(
            at: tmp.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"keyCode":10,"language":"de"}"#.utf8).write(to: tmp)
        XCTAssertEqual(Config.load(from: tmp).languages, ["de"])

        // "auto" was pre-1.2's default rather than a choice, so it migrates to
        // the system languages instead of the slow detect-among-100 path.
        try Data(#"{"language":"auto"}"#.utf8).write(to: tmp)
        XCTAssertEqual(Config.load(from: tmp).languages, Config.systemLanguages())

        // A deliberate empty list in a 1.2 config does mean "all languages".
        try Data(#"{"languages":[]}"#.utf8).write(to: tmp)
        XCTAssertEqual(Config.load(from: tmp).languages, [])
    }

    func testCorruptFileYieldsDefaults() throws {
        try FileManager.default.createDirectory(
            at: tmp.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: tmp)
        XCTAssertEqual(Config.load(from: tmp), freshInstall)
    }

    func testModelURLUsesModelName() {
        XCTAssertTrue(Config().modelURL.path.hasSuffix("models/ggml-large-v3-turbo.bin"))
    }
}
