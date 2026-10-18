import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Baixa uma URL para um arquivo local, reportando progresso.
public protocol Downloading: Sendable {
    /// - progress: (bytes recebidos, total esperado se conhecido)
    func download(
        _ url: URL,
        to destination: URL,
        progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws
}

/// Implementação com `URLSessionDownloadTask` + delegate (progresso confiável,
/// arquivo temporário movido de forma síncrona no callback, como a API exige).
public struct URLSessionDownloader: Downloading {
    public init() {}

    public func download(
        _ url: URL,
        to destination: URL,
        progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws {
        let delegate = DownloadDelegate(destination: destination, progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let task = session.downloadTask(with: url)
                delegate.start(task: task, continuation: continuation)
            }
        } onCancel: {
            delegate.cancel()
        }
    }
}

final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let destination: URL
    private let progress: @Sendable (Int64, Int64?) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDownloadTask?
    private var fileError: Error?

    init(destination: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    func start(task: URLSessionDownloadTask, continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        self.task = task
        self.continuation = continuation
        lock.unlock()
        task.resume()
    }

    func cancel() {
        lock.lock()
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            setFileError(WineError.downloadFailed(reason: "HTTP \(http.statusCode)"))
            return
        }
        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: location, to: destination)
        } catch {
            setFileError(error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let failure = error ?? fileError
        lock.unlock()

        if let failure {
            if (failure as? URLError)?.code == .cancelled {
                continuation?.resume(throwing: CancellationError())
            } else if failure is WineError {
                continuation?.resume(throwing: failure)
            } else {
                continuation?.resume(throwing: WineError.downloadFailed(reason: failure.localizedDescription))
            }
        } else {
            continuation?.resume()
        }
    }

    private func setFileError(_ error: Error) {
        lock.lock()
        fileError = error
        lock.unlock()
    }
}

public enum Checksum {
    /// SHA-256 em streaming (blocos de 4 MiB), em hexadecimal minúsculo.
    public static func sha256(of url: URL) throws -> String {
        #if canImport(CryptoKit)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        #else
        fatalError("SHA-256 requer CryptoKit")
        #endif
    }
}

public enum Archive {
    /// Extrai .tar.xz/.tar.gz/.zip usando o bsdtar do sistema (detecta o formato).
    public static func extract(_ archive: URL, to directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let result = try await FoundationProcessLauncher().collect(WineInvocation(
            executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-xf", archive.path, "-C", directory.path],
            environment: ProcessInfo.processInfo.environment
        ))
        guard result.exitCode == 0 else {
            throw WineError.invalidArchive(reason: result.stderr.suffix(5).joined(separator: "\n"))
        }
    }
}
