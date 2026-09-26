import Foundation
import Darwin
import RelayCore

func execCodex(_ path: String, _ args: [String]) -> Never {
    unsetenv("CODEX_CLI_PATH")
    let strings = ([path] + args).map { strdup($0) }
    var pointers = strings + [nil]
    _ = pointers.withUnsafeMutableBufferPointer { execv(path, $0.baseAddress!) }
    for s in strings { free(s) }
    FileHandle.standardError.write(Data("Relay: could not launch Codex.\n".utf8)); exit(127)
}
func reachable(_ path: String) -> Bool {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0); guard fd >= 0 else { return false }; defer { close(fd) }
    var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(URL(fileURLWithPath: path).resolvingSymlinksInPath().path.utf8) + [0]
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return false }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    return withUnsafePointer(to: &address) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0 } }
}
func ensureRuntime(_ paths: RelayPaths, args: [String]) throws {
    try paths.prepare()
    let lockPath = paths.root.appendingPathComponent("run/start.lock").path
    let lockFD = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    guard lockFD >= 0 else { throw RelayError.message("Could not open startup lock.") }
    defer { flock(lockFD, LOCK_UN); close(lockFD) }
    guard flock(lockFD, LOCK_EX) == 0 else { throw RelayError.message("Could not acquire startup lock.") }
    if reachable(paths.socket.path) {
        if let pid = RuntimeProcess.processID(paths: paths) {
            try? RelayPaths.privateWrite(Data(String(pid).utf8), to: paths.runtimePID)
        }
        return
    }
    // Only remove our own stale socket, never another user's endpoint or a symlink.
    var st = stat()
    if lstat(paths.socket.path, &st) == 0 {
        guard st.st_uid == getuid(), (st.st_mode & S_IFMT == S_IFSOCK || st.st_mode & S_IFMT == S_IFLNK) else { throw RelayError.message("Unsafe local socket path.") }
        try FileManager.default.removeItem(at: paths.socket)
    }
    let p = Process(); p.executableURL = URL(fileURLWithPath: paths.cli)
    var forwarded: [String] = []; var skip = false
    for arg in args {
        if skip { skip = false; continue }
        if arg == "--listen" { skip = true; continue }
        if arg == "--stdio" || arg.hasPrefix("--listen=") { continue }
        forwarded.append(arg)
    }
    p.arguments = forwarded + ["--listen", "unix://" + paths.socket.path]
    var env = ProcessInfo.processInfo.environment
    env.removeValue(forKey: "CODEX_CLI_PATH"); env.removeValue(forKey: "CODEX_APP_SERVER_WS_URL")
    p.environment = env; p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    try p.run()
    try RelayPaths.privateWrite(Data(String(p.processIdentifier).utf8), to: paths.runtimePID)
    for _ in 0..<200 {
        if reachable(paths.socket.path) { chmod(paths.socket.path, 0o600); return }
        if !p.isRunning { throw RelayError.message("Codex exited during startup.") }
        usleep(50_000)
    }
    p.terminate(); throw RelayError.message("Codex did not start within 10 seconds.")
}

@main struct RelayCLI {
    @MainActor static func main() async {
        let args = Array(CommandLine.arguments.dropFirst()), paths = RelayPaths()
        do {
            if args.first == "diagnose" {
                let c = ProcessChannel()
                try c.start(executable: paths.cli, arguments: ["app-server", "proxy", "--sock", paths.socket.path])
                defer { c.close() }
                let info = try await c.initialize(name: "relay_diagnostics")
                let list = try await c.call("thread/list", .object(["limit": .number(1)]))
                print("Runtime: connected\nProtocol: \(info["userAgent"].string ?? "unknown")\nTask listing: \(list["data"].array != nil ? "available" : "unavailable")")
                return
            }
            if args.contains("app-server"), !args.contains("proxy"), !args.contains("--help"), !args.contains("-h"), !args.contains("daemon"), !args.contains("generate-json-schema"), !args.contains("generate-ts") {
                try ensureRuntime(paths, args: args)
                let connection = LocalWebSocket(path: paths.socket.path, onData: { data in
                    var line = data; line.append(10); FileHandle.standardOutput.write(line)
                }, onClose: { exit(0) })
                while let line = readLine(strippingNewline: true) { connection.send(Data(line.utf8)) }
                connection.close(); return
            }
            execCodex(paths.cli, args)
        } catch { FileHandle.standardError.write(Data("Relay: \(error.localizedDescription)\n".utf8)); exit(1) }
    }
}
