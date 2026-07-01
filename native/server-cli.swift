// Standalone backend for development and tests: runs the same WavCaveServer the
// app embeds, without the GUI. Build with:
//   xcrun swiftc -parse-as-library Server.swift server-cli.swift -o wavcave-server
// Environment:
//   BF_PORT      port (default 8765)
//   BF_ROOT      static-file dir, where index.html lives (default: cwd)
//   BF_DATA_DIR  state/cache dir (default: ~/Library/Application Support/WavCave)
//   BF_TOKEN     API token; empty/unset disables token auth for local dev

import Foundation

@main
struct ServerCLI {
    static func main() {
        setbuf(stdout, nil)
        let env = ProcessInfo.processInfo.environment
        let port = UInt16(env["BF_PORT"] ?? "") ?? 8765
        let root = env["BF_ROOT"] ?? FileManager.default.currentDirectoryPath
        let data = env["BF_DATA_DIR"] ?? NSString(string: "~/Library/Application Support/WavCave").expandingTildeInPath
        let token = env["BF_TOKEN"] ?? ""
        let server = WavCaveServer(port: port, rootDir: root, dataDir: data, token: token)
        do { try server.start() } catch {
            FileHandle.standardError.write(Data("wavcave-server: \(error)\n".utf8))
            exit(1)
        }
        print("wavcave-server listening on http://127.0.0.1:\(port)  (root: \(root))")
        dispatchMain()
    }
}
