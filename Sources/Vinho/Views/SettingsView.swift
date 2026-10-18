import AppKit
import SwiftUI
import WineKit

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("Geral", systemImage: "gearshape") }
            RuntimesView()
                .tabItem { Label("Runtimes", systemImage: "shippingbox") }
        }
        .frame(width: 640, height: 520)
    }
}

private struct GeneralSettingsView: View {
    var body: some View {
        Form {
            Section("Armazenamento") {
                LabeledContent("Bottles", value: VinhoPaths.bottles.path)
                    .textSelection(.enabled)
                Button("Abrir no Finder") {
                    try? FileManager.default.createDirectory(at: VinhoPaths.bottles, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(VinhoPaths.bottles)
                }
            }

            Section("Sistema") {
                LabeledContent("Rosetta 2") {
                    if !SystemCheck.needsRosetta {
                        Text("não necessário (Intel)")
                    } else if SystemCheck.isRosettaInstalled {
                        Label("instalado", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Label("ausente", systemImage: "xmark.circle.fill").foregroundStyle(.red)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
