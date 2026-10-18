import Foundation

/// Modo de carregamento de uma DLL em `WINEDLLOVERRIDES`.
public enum DLLOverrideMode: String, Codable, CaseIterable, Sendable {
    case native = "n"
    case builtin = "b"
    case nativeThenBuiltin = "n,b"
    case builtinThenNative = "b,n"
    case disabled = ""
}

/// Recursos que um runtime Wine pode oferecer.
public enum RuntimeCapability: String, Codable, CaseIterable, Sendable {
    /// D3DMetal (Apple Game Porting Toolkit) embutido no runtime.
    case d3dMetal
    /// DXMT (Direct3D 10/11 → Metal).
    case dxmt
    /// DXVK (Direct3D 9/10/11 → Vulkan, via MoltenVK).
    case dxvk
}

/// Camada de tradução gráfica Direct3D usada por um bottle.
public enum GraphicsBackend: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Apple D3DMetal (D3D11/D3D12 → Metal). Melhor para jogos DX12.
    case d3dMetal
    /// DXMT (D3D10/11 → Metal). Open source, ótimo para DX11.
    case dxmt
    /// DXVK + MoltenVK (D3D9/10/11 → Vulkan → Metal).
    case dxvk
    /// WineD3D (D3D → OpenGL). Mais compatível, mais lento.
    case wined3d

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .d3dMetal: "D3DMetal"
        case .dxmt: "DXMT"
        case .dxvk: "DXVK"
        case .wined3d: "WineD3D"
        }
    }

    public var summary: String {
        switch self {
        case .d3dMetal: "DirectX 11/12 → Metal (Apple GPTK)"
        case .dxmt: "DirectX 10/11 → Metal (open source)"
        case .dxvk: "DirectX 10/11 → Vulkan → Metal (DXVK-macOS, legado)"
        case .wined3d: "DirectX → OpenGL (compatibilidade máxima)"
        }
    }

    /// Recurso que o runtime precisa ter para este backend funcionar.
    public var requiredCapability: RuntimeCapability? {
        switch self {
        case .d3dMetal: .d3dMetal
        case .dxmt: .dxmt
        case .dxvk: .dxvk
        case .wined3d: nil
        }
    }

    /// DLLs que este backend controla e como devem ser carregadas.
    ///
    /// Todos os backends são *builtin*: D3DMetal vem no runtime GPTK e
    /// DXMT/DXVK são instalados numa variante do runtime (veja
    /// `RuntimeInstaller.makeVariant`). Por isso o backend efetivo é
    /// decidido pelo runtime do bottle.
    public var dllOverrides: [String: DLLOverrideMode] {
        switch self {
        case .d3dMetal:
            ["dxgi": .builtin, "d3d9": .builtin, "d3d10core": .builtin, "d3d11": .builtin, "d3d12": .builtin]
        case .dxmt:
            ["dxgi": .builtin, "d3d10core": .builtin, "d3d11": .builtin, "winemetal": .builtin]
        case .dxvk:
            ["d3d10core": .builtin, "d3d11": .builtin]
        case .wined3d:
            ["dxgi": .builtin, "d3d9": .builtin, "d3d10core": .builtin, "d3d11": .builtin]
        }
    }
}

public enum DLLOverrides {
    /// Serializa overrides no formato do Wine: `"d3d11=n,b;dxgi=n,b"`.
    /// Ordenado para ser determinístico (e testável).
    public static func format(_ overrides: [String: DLLOverrideMode]) -> String {
        overrides
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.rawValue)" }
            .joined(separator: ";")
    }
}
