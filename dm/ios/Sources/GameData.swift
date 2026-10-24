// .nxrom reader shared by the iOS import UI and the Mac verification harness.
// No executable code is imported: the package contains only romfs/ and aoc/ files.
import Foundation
import CryptoKit

struct GameDataDescriptor: Codable {
    let format: Int
    let title_id, version, marker, sha256: String
    let size: UInt64
}

enum GameData {
    struct Entry: Decodable { let path: String; let size: UInt64 }
    struct Index: Decodable { let directories: [String]; let files: [Entry] }
    struct ImportError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    static func fail(_ message: String) -> ImportError { ImportError(message: message) }
    static func live(_ documents: URL) -> URL { documents.appendingPathComponent("game-data", isDirectory: true) }

    // Finish or roll back a swap interrupted by process termination. Both renames stay on one volume.
    static func recover(in documents: URL) throws {
        let fm = FileManager.default, backup = documents.appendingPathComponent(".game-data-backup")
        if fm.fileExists(atPath: backup.path) {
            if fm.fileExists(atPath: live(documents).path) { try fm.removeItem(at: backup) }
            else { try fm.moveItem(at: backup, to: live(documents)) }
        }
        // A killed import has no receipt and cannot be resumed; free its partial files before checking space.
        let staging = documents.appendingPathComponent(".game-data-import")
        if fm.fileExists(atPath: staging.path) { try fm.removeItem(at: staging) }
    }

    static func isInstalled(_ expected: GameDataDescriptor, in documents: URL) throws -> Bool {
        try recover(in: documents)
        let receipt = live(documents).appendingPathComponent("installed.json")
        guard FileManager.default.fileExists(atPath: receipt.path) else { return false }
        let actual = try JSONDecoder().decode(GameDataDescriptor.self, from: Data(contentsOf: receipt))
        return actual.sha256 == expected.sha256 && actual.format == expected.format
            && FileManager.default.fileExists(atPath: live(documents).appendingPathComponent("romfs/" + expected.marker).path)
    }

    static func validatePath(_ path: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.first == "romfs" || parts.first == "aoc",
              !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              !path.contains("\\"), !path.unicodeScalars.contains(where: { $0.value < 32 }) else {
            throw fail("Unsafe path in game-data package.")
        }
    }

    static func install(_ package: URL, expected: GameDataDescriptor, in documents: URL,
                        progress: (Double) -> Void) throws {
        let fm = FileManager.default
        guard expected.format == 1, expected.sha256.count == 64, expected.size >= 16 else {
            throw fail("Unsupported game-data descriptor. Rebuild the app.")
        }
        try recover(in: documents)
        let input = try FileHandle(forReadingFrom: package)
        defer { try? input.close() }
        guard try input.seekToEnd() == expected.size else {
            throw fail("This package is incomplete or belongs to another build. Select the .nxrom produced with this IPA.")
        }
        try input.seek(toOffset: 0)
        var digest = SHA256()
        func read(_ count: Int) throws -> Data {
            var result = Data()
            while result.count < count {
                guard let chunk = try input.read(upToCount: count - result.count), !chunk.isEmpty else {
                    throw fail("Game-data package is truncated.")
                }
                result.append(chunk)
            }
            digest.update(data: result)
            return result
        }
        let header = try read(16)
        guard header.prefix(8) == Data("NXROM001".utf8) else { throw fail("Select a .nxrom package, not an NSP or ZIP.") }
        let length = header.suffix(8).enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << ($1.offset * 8) }
        guard length > 0, length <= 64 << 20, length <= expected.size - 16 else { throw fail("Invalid game-data index size.") }
        let index = try JSONDecoder().decode(Index.self, from: read(Int(length)))
        var paths = Set<String>(), total = UInt64(16) + length
        for directory in index.directories {
            try validatePath(directory)
            guard paths.insert(directory).inserted else { throw fail("Duplicate game-data path.") }
        }
        guard paths.contains("romfs") else { throw fail("Game-data package has no RomFS.") }
        // Parents must be explicit directories; no symlinks, implicit traversal, or file/directory collisions.
        let directories = paths
        for entry in index.files {
            try validatePath(entry.path)
            guard paths.insert(entry.path).inserted, entry.size <= expected.size - total else { throw fail("Invalid game-data file table.") }
            total += entry.size
        }
        for path in paths where path.contains("/") {
            guard directories.contains(String(path.prefix(upTo: path.lastIndex(of: "/")!))) else { throw fail("Missing parent in game-data index.") }
        }
        guard total == expected.size else { throw fail("Game-data package size does not match its index.") }
        let free = try fm.attributesOfFileSystem(forPath: documents.path)[.systemFreeSize] as? NSNumber
        let needed = expected.size + UInt64(paths.count) * 4096 + (512 << 20)
        guard let free, free.uint64Value >= needed else {
            throw fail("Not enough free space to import. Free at least \(ByteCountFormatter.string(fromByteCount: Int64(needed), countStyle: .file)) and try again.")
        }
        let staging = documents.appendingPathComponent(".game-data-import", isDirectory: true)
        if fm.fileExists(atPath: staging.path) { try fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { if fm.fileExists(atPath: staging.path) { try? fm.removeItem(at: staging) } }
        var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
        var stagingURL = staging
        try stagingURL.setResourceValues(excluded)
        for directory in index.directories.sorted(by: { $0.count < $1.count }) {
            let destination = staging.appendingPathComponent(directory, isDirectory: true)
            guard !fm.fileExists(atPath: destination.path) else { throw fail("Game-data paths collide on this device.") }
            try fm.createDirectory(at: destination, withIntermediateDirectories: false)
        }
        var copied = UInt64(16) + length
        progress(Double(copied) / Double(expected.size))
        for entry in index.files {
            let destination = staging.appendingPathComponent(entry.path)
            guard !fm.fileExists(atPath: destination.path), fm.createFile(atPath: destination.path, contents: nil) else {
                throw fail("Cannot create game-data file, or paths collide on this device.")
            }
            let output = try FileHandle(forWritingTo: destination)
            do {
                var remaining = entry.size
                while remaining > 0 {
                    try autoreleasepool {
                        let chunk = try read(Int(min(remaining, 1 << 20)))
                        try output.write(contentsOf: chunk)
                        remaining -= UInt64(chunk.count)
                        copied += UInt64(chunk.count)
                    }
                    progress(Double(copied) / Double(expected.size))
                }
                try output.close()
            } catch { try? output.close(); throw error }
        }
        guard try input.read(upToCount: 1)?.isEmpty != false else { throw fail("Unexpected bytes after game data.") }
        let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard hash == expected.sha256 else {
            throw fail("Game-data verification failed. The package is damaged or does not match this IPA's game/update/DLC.")
        }
        guard fm.fileExists(atPath: staging.appendingPathComponent("romfs/" + expected.marker).path) else { throw fail("RomFS marker missing from package.") }
        try JSONEncoder().encode(expected).write(to: staging.appendingPathComponent("installed.json"), options: .atomic)
        let backup = documents.appendingPathComponent(".game-data-backup")
        if fm.fileExists(atPath: live(documents).path) { try fm.moveItem(at: live(documents), to: backup) }
        do { try fm.moveItem(at: staging, to: live(documents)) }
        catch {
            if fm.fileExists(atPath: backup.path) { try fm.moveItem(at: backup, to: live(documents)) }
            throw error
        }
        if fm.fileExists(atPath: backup.path) { try fm.removeItem(at: backup) }
        progress(1)
    }
}
