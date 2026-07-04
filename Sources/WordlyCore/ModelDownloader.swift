import Foundation

/// One-time download of the whisper model from Hugging Face (~1.6 GB for
/// large-v3-turbo). This is a build-time-style fetch of a static file — the
/// app makes no network calls during dictation.
public final class ModelDownloader: NSObject, URLSessionDownloadDelegate {
    public var onProgress: ((Int) -> Void)?               // percent, main thread
    public var onDone: ((Result<URL, Error>) -> Void)?    // main thread

    private let remote: URL
    private let destination: URL
    private lazy var session = URLSession(configuration: .default,
                                          delegate: self, delegateQueue: nil)

    public init(model: String, destination: URL) {
        self.remote = URL(string:
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-\(model).bin")!
        self.destination = destination
    }

    /// Calls back immediately if the file already looks complete (>1 GB —
    /// guards against a truncated earlier download of the 1.6 GB model).
    public func startIfNeeded() {
        let size = (try? FileManager.default.attributesOfItem(atPath: destination.path))?[.size] as? Int64 ?? 0
        if size > 1_000_000_000 {
            DispatchQueue.main.async { self.onDone?(.success(self.destination)) }
            return
        }
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
        if let error {
            DispatchQueue.main.async { self.onDone?(.failure(error)) }
        }
    }
}
