import AppKit
import SwiftUI
import WineKit

/// Cache de ícones extraídos dos executáveis (fora da main thread).
@MainActor
final class ProgramIconCache {
    static let shared = ProgramIconCache()

    private var images: [URL: NSImage] = [:]
    private var misses: Set<URL> = []

    func icon(for program: Program, in bottle: Bottle) async -> NSImage? {
        let url = program.iconURL ?? program.url
        if let cached = images[url] { return cached }
        if misses.contains(url) { return nil }

        let data = await Task.detached(priority: .utility) {
            ProgramIconResolver.iconData(for: url, in: bottle)
        }.value

        if let data, let image = NSImage(data: data) {
            images[url] = image
            return image
        }
        // Ícone de jogo que ainda está baixando: tenta de novo na próxima vez.
        if FileManager.default.fileExists(atPath: url.path) { misses.insert(url) }
        return nil
    }

    func invalidate() {
        images.removeAll()
        misses.removeAll()
    }
}

struct ProgramIconView: View {
    let program: Program
    let bottle: Bottle
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(6)
            } else {
                Image(systemName: program.kind == .custom ? "gamecontroller" : program.kind == .shortcut ? "app.badge" : "app")
                    .font(.system(size: 34))
            }
        }
        .frame(width: 64, height: 64)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
        .task(id: program.id) {
            image = await ProgramIconCache.shared.icon(for: program, in: bottle)
        }
    }
}
