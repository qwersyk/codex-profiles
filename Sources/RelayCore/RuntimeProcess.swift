import Foundation
import Darwin

/// Only the process recorded by this bridge, with its exact socket, may be stopped.
public enum RuntimeProcess {
    public static func stop(paths: RelayPaths) async throws {
        guard let data = try? String(contentsOf: paths.runtimePID, encoding: .utf8),
              let pid = Int32(data), pid > 1 else {
            guard !FileManager.default.fileExists(atPath: paths.socket.path) else {
                throw RelayError.message("Remote runtime has no valid process record. Quit ChatGPT and try again.")
            }
            return
        }
        if kill(pid, 0) != 0, errno == ESRCH { return }
        let probe = Process(), output = Pipe()
        probe.executableURL = URL(fileURLWithPath: "/bin/ps")
        probe.arguments = ["-ww", "-p", String(pid), "-o", "uid=,command="]
        probe.standardOutput = output; probe.standardError = FileHandle.nullDevice
        try probe.run()
        let command = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        probe.waitUntilExit()
        let fields = command.trimmingCharacters(in: .whitespacesAndNewlines).split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        guard fields.count == 2, fields[0] == String(getuid()),
              fields[1].hasPrefix(paths.cli + " "),
              fields[1].hasSuffix("--listen unix://" + paths.socket.path) else {
            if kill(pid, 0) != 0, errno == ESRCH { return }
            throw RelayError.message("Remote runtime could not be verified. Quit ChatGPT and try again.")
        }
        guard kill(pid, SIGTERM) == 0 || errno == ESRCH else { throw RelayError.message("Could not stop the Remote runtime.") }
        for _ in 0..<100 {
            if kill(pid, 0) != 0, errno == ESRCH {
                try? FileManager.default.removeItem(at: paths.runtimePID)
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw RelayError.message("Remote runtime is still shutting down. Try again.")
    }
}
