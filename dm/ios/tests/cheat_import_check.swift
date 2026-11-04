// Run the production importer on synthetic text files; no game files or simulator needed.
import Foundation

@main struct CheatImportCheck {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let build = "1111111111111111"
        let folder = root.appendingPathComponent("cheats")
        let original = "[Coins]\n04000000 00004000 00000063\n"
        func source(_ name: String, _ text: String) throws -> URL {
            let url = root.appendingPathComponent(name)
            try Data(text.utf8).write(to: url)
            return url
        }
        func rejected(_ url: URL, build: String = build) {
            do { _ = try CheatImport(url: url, build: build); fatalError("Accepted invalid input: \(url.lastPathComponent)") }
            catch {}
        }
        let named = try CheatImport(url: source("abcdef0123456789.TXT", original), build: build)
        precondition(named.name == "ABCDEF0123456789.txt" && !named.needsBuildConfirmation,
                     "Another build keeps its ID; it is never renamed to the running build")
        let plain = try CheatImport(url: source("coins.txt", original), build: build)
        precondition(plain.needsBuildConfirmation && plain.name == build + ".txt")
        try plain.install(in: folder)
        let destination = folder.appendingPathComponent(build + ".txt")
        let installed = try String(contentsOf: destination, encoding: .utf8)
        precondition(installed == original)
        let replacement = try CheatImport(url: source("replacement.txt", "[New]\n04000000 00004000 00000005\n"), build: build)
        try replacement.install(in: folder)
        let backup = try String(contentsOf: destination.appendingPathExtension("bak"), encoding: .utf8)
        precondition(backup == original, "Replacing a file preserves the original")
        let meta = try CheatImport(url: source("abcdef0123456789.meta.tsv", "name\tkind\nCoins\tdata\n"), build: build)
        precondition(meta.name == "ABCDEF0123456789.meta.tsv" && !meta.needsBuildConfirmation)
        try meta.install(in: folder)
        let unnamedMeta = try CheatImport(url: source("coins.meta.tsv", "name\tkind\nCoins\tdata\n"), build: build)
        precondition(unnamedMeta.needsBuildConfirmation && unnamedMeta.name == build + ".meta.tsv")
        rejected(try source("source.cheats.toml", "format = 1"))
        rejected(try source("empty.txt", ""))
        rejected(try source("binary.txt", "abc\0def"))
        rejected(try source("missing-build.txt", original), build: "")
        let large = root.appendingPathComponent("large.txt")
        try Data(repeating: 65, count: (4 << 20) + 1).write(to: large)
        rejected(large)
        let directory = root.appendingPathComponent("directory.txt")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        rejected(directory)
        precondition(!CheatImport.isBuild(String(repeating: "\u{FF11}", count: 16)))
        print("cheat import: passed (build matching, confirmation, metadata, backups, invalid inputs)")
    }
}
