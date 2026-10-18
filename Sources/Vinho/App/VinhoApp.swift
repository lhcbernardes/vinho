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
                .task {
                    model.registerOpenHandler()
                    await model.refresh()
                    await model.loadCommunityCatalog()
                    await model.checkForUpdatesIfDue()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    // Voltou para o Vinho: a Steam pode ter terminado algum download.
                    Task { await model.syncSteamLibraries() }
                }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Procurar Atualizações…") { Task { await model.checkForUpdates(userInitiated: true) } }
                    .disabled(model.isInstallingUpdate)
            }
            CommandGroup(replacing: .newItem) {
                Button("Novo Bottle…") { model.isCreatingBottle = true }
                    .keyboardShortcut("n")
                Button("Importar Bottle…") { model.importBottle() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Button("Receitas…") { model.isShowingRecipes = true }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            CommandMenu("Bottle") {
                Button("Executar Programa…") { model.isPickingProgram = true }
                    .keyboardShortcut("o")
                    .disabled(model.selectedBottle == nil)
                Button("Executar Comando…") { model.isRunningCommand = true }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(model.selectedBottle == nil)
                Button("Encerrar Todos os Processos") {
                    Task { await model.killAllInSelectedBottle() }
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(model.selectedBottle == nil)
                Divider()
                Button("Duplicar") {
                    if let bottle = model.selectedBottle { Task { await model.duplicate(bottle) } }
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(model.selectedBottle == nil)
                Button("Usar como Bottle Padrão") { model.setDefault(model.selectedBottle) }
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Necessário ao rodar via `swift run`: sem bundle, o processo nasce como
    /// "accessory" e a janela não recebe foco.
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Duplo clique num .exe/.msi/.lnk/.vinhobottle (Abrir com ▸ Vinho) ou
    /// arquivo arrastado no ícone do Dock.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { OpenFileRouter.open(urls) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
