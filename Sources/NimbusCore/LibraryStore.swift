import Foundation

public enum LibraryLoadError: LocalizedError {
    case unreadable(URL)
    case corrupted(URL)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let url):
            return L10n.f("Не удалось прочитать %@", url.path)
        case .corrupted(let url):
            return L10n.f("Файл библиотеки повреждён: %@", url.path)
        }
    }
}

public final class LibraryStore {
    public let url: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(url: URL = AppPaths.libraryURL) {
        self.url = url
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public func load() -> Library {
        (try? loadResult().get()) ?? Library()
    }

    public func loadResult() -> Result<Library, LibraryLoadError> {
        AppPaths.ensureDirectory(url.deletingLastPathComponent())
        guard FileManager.default.fileExists(atPath: url.path) else { return .success(Library()) }
        guard let data = try? Data(contentsOf: url) else { return .failure(.unreadable(url)) }
        do {
            return .success(try decoder.decode(Library.self, from: data))
        } catch {
            return .failure(.corrupted(url))
        }
    }

    public func loadBackup() -> Library? {
        let backup = url.appendingPathExtension("bak")
        guard let data = try? Data(contentsOf: backup) else { return nil }
        return try? decoder.decode(Library.self, from: data)
    }

    public func copyUnreadBackup() -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "library.unread-\(formatter.string(from: Date())).json"
        let destination = url.deletingLastPathComponent().appendingPathComponent(name)
        do {
            try FileManager.default.copyItem(at: url, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    /// Moves a corrupt file aside instead of letting the next save overwrite it.
    public func quarantineCorruptFile() -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "library.corrupt-\(formatter.string(from: Date())).json"
        let destination = url.deletingLastPathComponent().appendingPathComponent(name)
        do {
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    public func save(_ library: Library) throws {
        AppPaths.ensureDirectory(url.deletingLastPathComponent())
        let data = try encoder.encode(library)
        if FileManager.default.fileExists(atPath: url.path) {
            let backup = url.appendingPathExtension("bak")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: url, to: backup)
        }
        try data.write(to: url, options: .atomic)
    }

    public func export(_ library: Library, to destination: URL) throws {
        let data = try encoder.encode(library)
        try data.write(to: destination, options: .atomic)
    }

    public func importLibrary(from source: URL) throws -> Library {
        let data = try Data(contentsOf: source)
        return try decoder.decode(Library.self, from: data)
    }
}
