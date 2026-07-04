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

    func testMissingFileYieldsDefaultsAndCreatesFile() {
        let c = Config.load(from: tmp)
        XCTAssertEqual(c, Config())
        XCTAssertEqual(c.keyCode, 10)
        XCTAssertEqual(c.language, "auto")
        XCTAssertFalse(c.cleanupEnabled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.path))
    }

    func testRoundTrip() {
        var c = Config()
        c.cleanupEnabled = true
        c.language = "de"
        c.save(to: tmp)
        XCTAssertEqual(Config.load(from: tmp), c)
    }

    func testCorruptFileYieldsDefaults() throws {
        try FileManager.default.createDirectory(
            at: tmp.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: tmp)
        XCTAssertEqual(Config.load(from: tmp), Config())
    }

    func testModelURLUsesModelName() {
        XCTAssertTrue(Config().modelURL.path.hasSuffix("models/ggml-large-v3-turbo.bin"))
    }
}
