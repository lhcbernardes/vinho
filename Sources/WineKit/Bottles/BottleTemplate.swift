import Foundation

/// Modelos prontos para criar bottles (como os templates do CrossOver):
/// versão do Windows, gráficos e componentes instalados logo após a criação.
public struct BottleTemplate: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let summary: String
    /// SF Symbol.
    public let symbol: String
    public let windows: WindowsVersion
    public let graphics: GraphicsBackend
    public let sync: SyncMode?
    /// Ids de `WindowsComponents`.
    public let components: [String]
    public init(id: String, name: String, summary: String, symbol: String, windows: WindowsVersion,
                graphics: GraphicsBackend, sync: SyncMode?, components: [String]) {
        self.id = id
        self.name = name
        self.summary = summary
        self.symbol = symbol
        self.windows = windows
        self.graphics = graphics
        self.sync = sync
        self.components = components
    }

    /// Precisa de um runtime com este backend (ex.: D3DMetal para DX12).
    public var requiredBackend: GraphicsBackend? { graphics == .wined3d ? nil : graphics }

    public var preset: BottlePreset {
        BottlePreset(windows: windows, graphics: graphics, sync: sync)
    }

    public static let all: [BottleTemplate] = [
        BottleTemplate(
            id: "apps", name: "Aplicativos", summary: "Programas comuns. Windows 10, gráficos do Wine.",
            symbol: "macwindow", windows: .win10, graphics: .wined3d, sync: nil, components: []),
        BottleTemplate(
            id: "office", name: "Office e .NET", summary: "Programas de escritório e apps .NET: Wine Mono e fontes da Microsoft.",
            symbol: "doc.richtext", windows: .win10, graphics: .wined3d, sync: nil,
            components: ["wine-mono", "corefonts"]),
        BottleTemplate(
            id: "games", name: "Jogos DirectX 9–11", summary: "DXMT para DX10/11, Visual C++ e DirectX 9 já instalados.",
            symbol: "gamecontroller", windows: .win10, graphics: .dxmt, sync: .msync,
            components: ["vcrun2022", "d3dx9"]),
        BottleTemplate(
            id: "games-dx12", name: "Jogos DirectX 12", summary: "D3DMetal (Game Porting Toolkit) com Windows 11 e Visual C++.",
            symbol: "sparkles", windows: .win11, graphics: .d3dMetal, sync: .msync,
            components: ["vcrun2022"]),
        BottleTemplate(
            id: "retro", name: "Jogos antigos", summary: "Windows 7, DirectX 9, Visual C++ 2008 e áudio XACT.",
            symbol: "arcade.stick", windows: .win7, graphics: .wined3d, sync: .msync,
            components: ["d3dx9", "vcrun2008", "xact"]),
        BottleTemplate(
            id: "empty", name: "Vazio", summary: "Sem nada extra: você escolhe tudo.",
            symbol: "square.dashed", windows: .win10, graphics: .dxmt, sync: nil, components: []),
    ]

    public var windowsComponents: [WindowsComponent] {
        components.compactMap(WindowsComponents.component)
    }
}
