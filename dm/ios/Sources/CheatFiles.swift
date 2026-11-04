// Import compiled Atmosphere files into the app's cheats folder. No game memory is touched here.
import Foundation

struct CheatImport {
    let name: String
    let data: Data
    let needsBuildConfirmation: Bool

    init(url: URL, build: String) throws {
        let source = url.lastPathComponent
        let suffix: String
        if source.lowercased().hasSuffix(".meta.tsv") { suffix = ".meta.tsv" }
        else if url.pathExtension.lowercased() == "txt" { suffix = ".txt" }
        else { throw Self.error("Choose an Atmosphere .txt file or its .meta.tsv companion.") }
        let stem = String(source.dropLast(suffix.count))
        let namedBuild = Self.isBuild(stem)
        guard namedBuild || Self.isBuild(build) else {
            throw Self.error("This app has no game Build ID. Import a file named after its Build ID.")
        }
        needsBuildConfirmation = !namedBuild
        name = (namedBuild ? stem.uppercased() : build.uppercased()) + suffix

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
            result = Result {
                let info = try readable.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard info.isRegularFile == true, let size = info.fileSize, size > 0, size <= 4 << 20 else {
                    throw Self.error("Choose a nonempty cheat file smaller than 4 MiB.")
                }
                let bytes = try Data(contentsOf: readable)
                guard bytes.count <= 4 << 20, !bytes.contains(0), String(data: bytes, encoding: .utf8) != nil else {
                    throw Self.error("The cheat file must be UTF-8 text smaller than 4 MiB.")
                }
                return bytes
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw Self.error("The selected file could not be read.") }
        data = try result.get()
    }

    func install(in folder: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(name)
        if fm.fileExists(atPath: destination.path) {
            // Keep the previous contents even if writing the replacement fails.
            try Data(contentsOf: destination).write(to: destination.appendingPathExtension("bak"), options: .atomic)
        }
        try data.write(to: destination, options: .atomic)
    }

    static func isBuild(_ text: String) -> Bool {
        text.utf8.count == 16 && text.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "nxnative.cheats", code: 1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString(message, comment: "Cheat import")])
    }
}
