import XCTest
@testable import WordlyCore

final class AudioTrimTests: XCTestCase {
    // Build a 16 kHz buffer: `lead` s silence, `speech` s tone, `tail` s silence.
    private func buffer(lead: Double, speech: Double, tail: Double,
                        amp: Float = 0.5) -> [Float] {
        let sr = 16000
        let silence = { (s: Double) in [Float](repeating: 0, count: Int(s * Double(sr))) }
        let tone = (0..<Int(speech * Double(sr))).map { i in
            amp * sinf(2 * .pi * 220 * Float(i) / Float(sr))
        }
        return silence(lead) + tone + silence(tail)
    }

    func testTrimsLeadingAndTrailingSilence() {
        let trimmed = AudioTrim.trim(buffer(lead: 1.0, speech: 1.0, tail: 1.0))
        // ~1 s speech + 0.1 s padding each side ≈ 1.2 s = 19200 samples, well
        // under the original 3 s (48000) and comfortably over the bare 1 s.
        XCTAssertLessThan(trimmed.count, 48000)
        XCTAssertGreaterThan(trimmed.count, 16000)
        XCTAssertLessThan(trimmed.count, 24000)
    }

    func testKeepsPaddingAroundSpeech() {
        let sr = 16000
        let trimmed = AudioTrim.trim(buffer(lead: 2.0, speech: 0.5, tail: 2.0))
        // 0.5 s speech + 0.2 s total padding ≈ 0.7 s; assert padding present.
        XCTAssertGreaterThanOrEqual(trimmed.count, Int(0.5 * Double(sr)))
        XCTAssertLessThan(trimmed.count, Int(1.0 * Double(sr)))
    }

    func testAllSilenceReturnedUnchanged() {
        let silence = [Float](repeating: 0, count: 16000)
        XCTAssertEqual(AudioTrim.trim(silence).count, 16000)
    }

    func testShortBufferReturnedUnchanged() {
        let tiny = [Float](repeating: 0.5, count: 50)
        XCTAssertEqual(AudioTrim.trim(tiny), tiny)
    }

    func testPureSpeechBarelyTrimmed() {
        let trimmed = AudioTrim.trim(buffer(lead: 0, speech: 1.0, tail: 0))
        XCTAssertEqual(Double(trimmed.count), 16000, accuracy: 3200)  // ±0.2 s
    }
}
