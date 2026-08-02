import XCTest
@testable import WordlyCore

final class UserDictionaryTests: XCTestCase {
    var url: URL!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wordly-dict-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("dictionary.txt")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    func testParsesTermsSkippingCommentsAndBlanks() throws {
        try "# comment\n\nWordly\n  Kubernetes  \n#x\nJulian Hartung\n".write(
            to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(UserDictionary(url: url).terms(), ["Wordly", "Kubernetes", "Julian Hartung"])
    }

    func testMissingFileCreatesTemplateAndReturnsEmpty() {
        let dict = UserDictionary(url: url)
        XCTAssertEqual(dict.terms(), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testHotReloadOnMtimeChange() throws {
        try "Alpha\n".write(to: url, atomically: true, encoding: .utf8)
        let dict = UserDictionary(url: url)
        XCTAssertEqual(dict.terms(), ["Alpha"])
        try "Beta\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: url.path)
        XCTAssertEqual(dict.terms(), ["Beta"])
    }

    func testInitialPrompt() throws {
        try "Wordly\nOllama\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(UserDictionary(url: url).initialPrompt(), "Wordly, Ollama.")
        try "".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(UserDictionary(url: url).initialPrompt(), "")
    }
}
