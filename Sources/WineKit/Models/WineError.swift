import Foundation

public enum WineError: Error, LocalizedError, Equatable {
    case noRuntimeAvailable
    case runtimeNotFound(id: String)
    case launchFailed(executable: String, reason: String)
    case nonZeroExit(command: String, code: Int32, stderrTail: String)
    case bottleAlreadyExists(name: String)
    case invalidBottleName
    case notABottle(path: String)
    case backendUnsupported(backend: GraphicsBackend, runtime: String)
    case downloadFailed(reason: String)
    case checksumMismatch(expected: String, actual: String)
    case invalidArchive(reason: String)
    case alreadyInstalled(id: String)
    case notManagedRuntime(id: String)

    public var errorDescription: String? {
        switch self {
        case .noRuntimeAvailable:
            "Nenhum runtime Wine encontrado. Instale um runtime (veja o README)."
        case .runtimeNotFound(let id):
            "Runtime \"\(id)\" não encontrado."
        case .launchFailed(let exe, let reason):
            "Falha ao iniciar \(exe): \(reason)"
        case .nonZeroExit(let cmd, let code, let tail):
            "\(cmd) terminou com código \(code).\n\(tail)"
        case .bottleAlreadyExists(let name):
            "Já existe um bottle chamado \"\(name)\"."
        case .invalidBottleName:
            "Nome de bottle inválido."
        case .notABottle(let path):
            "\(path) não é um bottle do Vinho."
        case .backendUnsupported(let backend, let runtime):
            "O runtime \"\(runtime)\" não suporta \(backend.displayName)."
        case .downloadFailed(let reason):
            "Falha no download: \(reason)"
        case .checksumMismatch(let expected, let actual):
            "O arquivo baixado está corrompido ou foi alterado (SHA-256 esperado \(expected.prefix(12))…, obtido \(actual.prefix(12))…)."
        case .invalidArchive(let reason):
            "Pacote inválido: \(reason)"
        case .alreadyInstalled(let id):
            "\"\(id)\" já está instalado."
        case .notManagedRuntime(let id):
            "\"\(id)\" não foi instalado pelo Vinho e não pode ser removido por aqui."
        }
    }
}
