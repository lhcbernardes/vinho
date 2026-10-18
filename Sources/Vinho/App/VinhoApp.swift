import AppKit
import SwiftUI

@main
struct VinhoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Vinho") {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 560)
                .task { await model.refresh() }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Novo Bottle…") { model.isCreatingBottle = true }
                    .keyboardShortcut("n")
                Button("Importar Bottle…") { model.importBottle() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
            }
            CommandMenu("Bottle") {
                Button("Executar Programa…") { model.isPickingProgram = true }
                    .keyboardShortcut("o")
                    .disabled(model.selectedBottle == nil)
                Button("Encerrar Todos os Processos") {
                    Task { await model.killAllInSelectedBottle() }
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(model.selectedBottle == nil)
                Divider()
                Button("Recarregar") { Task { await model.refresh() } }
                    .keyboardShortcut("r")
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

/// Necessário ao rodar via `swift run`: sem bundle, o processo nasce como
/// "accessory" e a janela não recebe foco.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
