import Foundation

@main
struct GameDataHarness {
    static func main() throws {
        let args = CommandLine.arguments
        let expected = try JSONDecoder().decode(GameDataDescriptor.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
        let documents = URL(fileURLWithPath: args[3], isDirectory: true)
        do {
            if args[1] == "install" {
                var last = 0.0
                try GameData.install(URL(fileURLWithPath: args[4]), expected: expected, in: documents) {
                    precondition($0 >= last && $0 <= 1)
                    last = $0
                }
                precondition(last == 1)
            }
            guard try GameData.isInstalled(expected, in: documents) else { throw GameData.fail("Not installed") }
            print("ready")
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
