import Foundation

struct AudioBook: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var filename: String
    var addedAt: Date
    var progress: Double
}

@MainActor
final class AudioLibrary: ObservableObject {
    @Published private(set) var books: [AudioBook] = []
    @Published var selectedID: UUID?
    @Published var errorMessage: String?

    private var root: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    private var manifest: URL { root.appendingPathComponent("tingx-library.json") }

    init() { load() }
    var selected: AudioBook? { books.first(where: { $0.id == selectedID }) }

    func importFiles(_ urls: [URL]) {
        for url in urls {
            let ext = url.pathExtension.lowercased()
            guard ext == "epub" || ext == "txt" else {
                errorMessage = "仅支持 EPUB 和 TXT 文件。"
                continue
            }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let id = UUID()
            let destination = root.appendingPathComponent(id.uuidString + "." + ext)
            do {
                try FileManager.default.copyItem(at: url, to: destination)
                let book = AudioBook(id: id, title: url.deletingPathExtension().lastPathComponent,
                                     filename: destination.lastPathComponent, addedAt: .now, progress: 0)
                books.insert(book, at: 0)
                selectedID = id
            } catch {
                errorMessage = "导入失败：\(error.localizedDescription)"
            }
        }
        save()
    }

    func select(_ book: AudioBook) { selectedID = book.id; save() }

    func delete(_ book: AudioBook) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(book.filename))
        books.removeAll(where: { $0.id == book.id })
        if selectedID == book.id { selectedID = books.first?.id }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: manifest),
              let state = try? JSONDecoder().decode(SavedLibrary.self, from: data) else { return }
        books = state.books.filter { FileManager.default.fileExists(atPath: root.appendingPathComponent($0.filename).path) }
        selectedID = state.selectedID
    }

    private func save() {
        let state = SavedLibrary(books: books, selectedID: selectedID)
        guard let data = try? JSONEncoder().encode(state) else { return }
        do { try data.write(to: manifest, options: .atomic) }
        catch { errorMessage = "保存书架失败：\(error.localizedDescription)" }
    }

    private struct SavedLibrary: Codable {
        var books: [AudioBook]
        var selectedID: UUID?
    }
}
