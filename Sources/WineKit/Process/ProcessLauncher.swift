import Foundation

/// Tudo que é preciso para executar um processo. Valor puro: fácil de testar.
public struct WineInvocation: Sendable, Equatable {
    public var executable: URL
    public var arguments: [String]
    public var environment: [String: String]
    public var currentDirectory: URL?

    public init(executable: URL, arguments: [String], environment: [String: String], currentDirectory: URL? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.currentDirectory = currentDirectory
    }

    /// Representação legível para logs.
    public var commandLine: String {
        ([executable.lastPathComponent] + arguments.map(Self.quote)).joined(separator: " ")
    }

    private static func quote(_ s: String) -> String {
        s.contains(" ") ? "\"\(s)\"" : s
    }
}

public enum ProcessEvent: Sendable, Equatable {
    case stdout(String)
    case stderr(String)
    case exited(Int32)
}

public struct ProcessResult: Sendable, Equatable {
    public var command: String
    public var exitCode: Int32
    public var stdout: [String]
    public var stderr: [String]

    @discardableResult
    public func check() throws -> ProcessResult {
        guard exitCode == 0 else {
            throw WineError.nonZeroExit(
                command: command, code: exitCode,
                stderrTail: stderr.suffix(15).joined(separator: "\n")
            )
        }
        return self
    }
}

/// Abstração sobre `Process` para permitir testes sem Wine instalado.
public protocol ProcessLaunching: Sendable {
    func run(_ invocation: WineInvocation) -> AsyncThrowingStream<ProcessEvent, Error>
}

/// Implementação real baseada em `Foundation.Process`.
public struct FoundationProcessLauncher: ProcessLaunching {
    public init() {}

    public func run(_ invocation: WineInvocation) -> AsyncThrowingStream<ProcessEvent, Error> {
        AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = invocation.executable
            process.arguments = invocation.arguments
            process.environment = invocation.environment
            if let cwd = invocation.currentDirectory {
                process.currentDirectoryURL = cwd
            }

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            process.standardInput = FileHandle.nullDevice

            let outLines = LineBuffer { continuation.yield(.stdout($0)) }
            let errLines = LineBuffer { continuation.yield(.stderr($0)) }

            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil } else { outLines.append(data) }
            }
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil } else { errLines.append(data) }
            }

            // Importante: não usamos readDataToEndOfFile() aqui. O wineserver
            // herda os pipes e continua vivo depois que `wine` sai, então
            // esperar EOF travaria para sempre.
            process.terminationHandler = { proc in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                outLines.flush()
                errLines.flush()
                continuation.yield(.exited(proc.terminationStatus))
                continuation.finish()
            }

            continuation.onTermination = { reason in
                if case .cancelled = reason, process.isRunning {
                    process.terminate()
                }
            }

            do {
                try process.run()
            } catch {
                continuation.finish(throwing: WineError.launchFailed(
                    executable: invocation.executable.path,
                    reason: error.localizedDescription
                ))
            }
        }
    }
}

/// Acumula bytes e emite linhas completas (UTF-8, sem `\r\n`).
final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let emit: (String) -> Void

    init(emit: @escaping (String) -> Void) {
        self.emit = emit
    }

    func append(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newline]
            lines.append(Self.decode(lineData))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        lock.unlock()
        lines.forEach(emit)
    }

    func flush() {
        lock.lock()
        let rest = buffer
        buffer.removeAll()
        lock.unlock()
        if !rest.isEmpty { emit(Self.decode(rest)) }
    }

    private static func decode(_ data: Data) -> String {
        var s = String(decoding: data, as: UTF8.self)
        if s.hasSuffix("\r") { s.removeLast() }
        return s
    }
}
