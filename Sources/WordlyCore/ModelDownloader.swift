import Foundation

/// One-time download of the whisper model from Hugging Face (~1.6 GB for
/// large-v3-turbo). This is a build-time-style fetch of a static file — the
/// app makes no network calls during dictation.
public final class ModelDownloader: NSObject, URLSessionDownloadDelegate {
    public var onProgress: ((Int) -> Void)?               // percent, main thread
    public var onDone: ((Result<URL, Error>) -> Void)?    // main thread

    private let remote: URL
    private let destination: URL
    private var isDownloading = false  // main-thread confined, like the callbacks
    // Per-attempt: a URLSession can't be reused after invalidation (CFNetwork
    // raises an uncatchable NSException), so each retry gets a fresh one.
    private var session: URLSession?

    public init(model: String, destination: URL) {
        self.remote = URL(string:
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-\(model).bin")!
        self.destination = destination
    }

    /// Calls back immediately if the file already looks complete (>1 GB —
    /// guards against a truncated earlier download of the 1.6 GB model).
    public func startIfNeeded() {
        guard !isDownloading else { return }  // re-entrant call must not start a 2nd task
        let size = (try? FileManager.default.attributesOfItem(atPath: destination.path))?[.size] as? Int64 ?? 0
        if size > 1_000_000_000 {
            DispatchQueue.main.async { self.onDone?(.success(self.destination)) }
            return
        }
        isDownloading = true
        let session = URLSession(configuration: .default,
                                 delegate: self, delegateQueue: nil)
        self.session = session
        session.downloadTask(with: remote).resume()
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                           didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                           totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let percent = Int(totalBytesWritten * 100 / totalBytesExpectedToWrite)
        DispatchQueue.main.async { self.onProgress?(percent) }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                           didFinishDownloadingTo location: URL) {
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: destination.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: location, to: destination)
            DispatchQueue.main.async { self.onDone?(.success(self.destination)) }
        } catch {
            DispatchQueue.main.async { self.onDone?(.failure(error)) }
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           didCompleteWithError error: Error?) {
        // Always fires last (also after a successful download, with error nil):
        // the right place to reset state and release the session+delegate pair.
        session.finishTasksAndInvalidate()
        DispatchQueue.main.async {
            self.isDownloading = false
            self.session = nil
            if let error { self.onDone?(.failure(error)) }
        }
    }
}
