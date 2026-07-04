import XCTest
@testable import WordlyCore

final class CleanerTests: XCTestCase {
    func testParseValidResponse() {
        let json = #"{"message":{"role":"assistant","content":"  Clean text.  "}}"#
        XCTAssertEqual(Cleaner.parseResponse(Data(json.utf8)), "Clean text.")
    }

    func testParseGarbageReturnsNil() {
        XCTAssertNil(Cleaner.parseResponse(Data("not json".utf8)))
        XCTAssertNil(Cleaner.parseResponse(Data(#"{"error":"model not found"}"#.utf8)))
    }

    func testBuildBodyContainsTranscriptModelAndTerms() throws {
        let body = Cleaner.buildBody(text: "ähm hallo welt",
                                     terms: ["Wordly"], model: "gemma3:4b")
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(obj["model"] as? String, "gemma3:4b")
        XCTAssertEqual(obj["stream"] as? Bool, false)
        let messages = try XCTUnwrap(obj["messages"] as? [[String: Any]])
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertTrue((messages[0]["content"] as? String ?? "").contains("Wordly"))
        XCTAssertEqual(messages[1]["content"] as? String, "ähm hallo welt")
    }

    func testUnreachableServerFailsOpen() async {
        let raw = "raw transcript"
        let out = await Cleaner.clean(raw, terms: [], model: "gemma3:4b",
            endpoint: URL(string: "http://127.0.0.1:1")!, timeout: 2)
        XCTAssertEqual(out, raw)
    }
}
