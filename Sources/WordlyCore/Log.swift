import Foundation
import os

/// One line of diagnostics, readable afterwards with:
///
///     log show --predicate 'subsystem == "dev.wordly.Wordly"' --last 10m --style compact
///
/// This replaced `NSLog`, whose output could only be found by grepping
/// everything the process ever logged — thousands of rows of CoreAudio and
/// Spotlight chatter around each of our lines. A dedicated subsystem makes the
/// predicate exact, which is the difference between a debugging instruction that
/// works and one nobody can follow.
///
/// The message is interpolated as `.public` on purpose — os.Logger redacts
/// interpolated values to `<private>` by default, and a diagnostic line full of
/// `<private>` helps nobody. Nothing logged here is sensitive: durations,
/// language codes, window geometry. Transcripts are never logged.
public func wordlyLog(_ message: String) {
    Logger.wordly.notice("\(message, privacy: .public)")
}

extension Logger {
    static let wordly = Logger(subsystem: "dev.wordly.Wordly", category: "wordly")
}
