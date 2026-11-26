import Foundation

enum DownloadError: LocalizedError {
    case http(Int, String)
    case cancelled
    var errorDescription: String? {
        switch self {
        case .http(let code, let url): return "Server returned \(code) for \(url)"
        case .cancelled: return "Download cancelled"
        }
    }
}

/// Downloads one file at a time with progress, retrying with resume data on network drops.
final class FileDownloader: NSObject, URLSessionDownloadDelegate {
    private var session: URLSession!
    private var continuation: CheckedContinuation<Void, Error>?
    private var progressHandler: ((Int64, Int64) -> Void)?
    private var destination: URL?
    private var task: URLSessionDownloadTask?
    private var resumeData: Data?
    private(set) var isCancelled = false
    private let lock = NSLock()

    override init() {
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 60 * 60 * 24
        cfg.waitsForConnectivity = true
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    func cancel() {
        isCancelled = true
        task?.cancel()
    }

    func download(_ url: URL, to dest: URL, progress: @escaping (Int64, Int64) -> Void) async throws {
        var attempt = 0
        resumeData = nil
        while true {
            if isCancelled { throw DownloadError.cancelled }
            do {
                try await single(url, to: dest, progress: progress)
                return
            } catch {
                attempt += 1
                if isCancelled { throw DownloadError.cancelled }
                if case DownloadError.http = error { throw error }
                if attempt >= 8 { throw error }
                try? await Task.sleep(nanoseconds: UInt64(min(attempt, 5)) * 2_000_000_000)
            }
        }
    }

    private func single(_ url: URL, to dest: URL, progress: @escaping (Int64, Int64) -> Void) async throws {
        destination = dest
        progressHandler = progress
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            lock.lock()
            continuation = c
            lock.unlock()
            let t: URLSessionDownloadTask
            if let data = resumeData {
                t = session.downloadTask(withResumeData: data)
            } else {
                var req = URLRequest(url: url)
                req.setValue("Imagine-iOS/1.0", forHTTPHeaderField: "User-Agent")
                t = session.downloadTask(with: req)
            }
            resumeData = nil
            task = t
            t.resume()
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(with: result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progressHandler?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            finish(.failure(DownloadError.http(http.statusCode, downloadTask.originalRequest?.url?.absoluteString ?? "")))
            return
        }
        guard let dest = destination else { finish(.failure(DownloadError.cancelled)); return }
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: location, to: dest)
            finish(.success(()))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let ns = error as NSError
        if let data = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            resumeData = data
        }
        finish(.failure(isCancelled ? DownloadError.cancelled : error))
    }
}
