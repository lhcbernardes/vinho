import Foundation

/// Pré-requisitos do sistema.
public enum SystemCheck {
    /// Builds do Wine para macOS são x86_64; no Apple Silicon precisam do Rosetta 2.
    public static var needsRosetta: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    public static var isRosettaInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime")
    }

    public static var rosettaInstallCommand: String {
        "softwareupdate --install-rosetta --agree-to-license"
    }
}
