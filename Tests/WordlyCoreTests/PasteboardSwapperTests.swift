import XCTest
import AppKit
@testable import WordlyCore

final class PasteboardSwapperTests: XCTestCase {
    var pb: NSPasteboard!

    override func setUp() {
        pb = NSPasteboard(name: NSPasteboard.Name("wordly-test-\(UUID().uuidString)"))
    }

    override func tearDown() {
        pb.releaseGlobally()
    }

    func testPlaceSetsTranscript() {
        let swapper = PasteboardSwapper(pasteboard: pb)
        swapper.place("hello dictation")
        XCTAssertEqual(pb.string(forType: .string), "hello dictation")
    }

    func testRestoreBringsBackPriorString() {
        pb.clearContents()
        pb.setString("user copy", forType: .string)
        let swapper = PasteboardSwapper(pasteboard: pb)
        swapper.place("transcript")
        swapper.restoreIfUnchanged()
        XCTAssertEqual(pb.string(forType: .string), "user copy")
    }

    func testRestoreBringsBackNonStringData() {
        pb.clearContents()
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        pb.setData(payload, forType: .tiff)
        let swapper = PasteboardSwapper(pasteboard: pb)
        swapper.place("transcript")
        swapper.restoreIfUnchanged()
        XCTAssertEqual(pb.data(forType: .tiff), payload)
        XCTAssertNil(pb.string(forType: .string))
    }

    func testSkipsRestoreIfUserCopiedMeanwhile() {
        pb.clearContents()
        pb.setString("old", forType: .string)
        let swapper = PasteboardSwapper(pasteboard: pb)
        swapper.place("transcript")
        pb.clearContents()
        pb.setString("newer copy", forType: .string)   // user copied during the 200 ms
        swapper.restoreIfUnchanged()
        XCTAssertEqual(pb.string(forType: .string), "newer copy")
    }

    func testRestoreOfEmptyPasteboardLeavesItEmpty() {
        pb.clearContents()
        let swapper = PasteboardSwapper(pasteboard: pb)
        swapper.place("transcript")
        swapper.restoreIfUnchanged()
        XCTAssertNil(pb.string(forType: .string))
    }
}
