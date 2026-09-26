import Foundation
import Darwin

/// Only the process recorded by this bridge, with its exact socket, may be stopped.
public enum RuntimeProcess {
    public static func processID(paths: RelayPaths) -> Int32? {
        let probe = Process(), output = Pipe()
        probe.executableURL = URL(fileURLWithPath: "/bin/ps")
        probe.arguments = ["-ww", "-axo", "uid=,pid=,command="]
        probe.standardOutput = output; probe.standardError = FileHandle.nullDevice
        guard (try? probe.run()) != nil else { return nil }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        probe.waitUntilExit()
        let listen = "--listen unix://" + paths.socket.path
        let cliPaths = paths.cliCandidates
        return text.split(separator: "\n").compactMap { line in
            let fields = line.split(maxSplits: 2, whereSeparator: { $0.isWhitespace })
            guard fields.count == 3,
                  fields[0] == String(getuid()),
                  cliPaths.contains(where: { fields[2].hasPrefix($0 + " ") }),
                  fields[2].contains(" app-server "),
                  fields[2].hasSuffix(listen),
                  let pid = Int32(fields[1]), pid > 1 else { return nil }
            return pid
        }.first
    }

    public static func stop(paths: RelayPaths) async throws {
        let recordedPID = (try? String(contentsOf: paths.runtimePID, encoding: .utf8))
            .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let discoveredPID = processID(paths: paths)
        let candidates = [recordedPID, discoveredPID].compactMap { $0 }.filter { $0 > 1 }
        guard let pid = candidates.first(where: { verified($0, paths: paths) }) else {
            // A previous runtime may have exited before shutdown was requested.
            // Only discard its record when neither that process nor its socket remains.
            if let recordedPID, recordedPID > 1,
               kill(recordedPID, 0) != 0, errno == ESRCH,
               !FileManager.default.fileExists(atPath: paths.socket.path) {
                try removeRecord(ifMatching: recordedPID, paths: paths)
                return
            }
            if recordedPID != nil {
                throw RelayError.message("Remote runtime could not be verified. Quit ChatGPT and try again.")
            }
            guard !FileManager.default.fileExists(atPath: paths.socket.path) else {
                throw RelayError.message("Remote runtime has no valid process record. Quit ChatGPT and try again.")
            }
            return
        }
        if kill(pid, 0) != 0, errno == ESRCH { return }
        guard verified(pid, paths: paths) else { throw RelayError.message("Remote runtime could not be verified. Quit ChatGPT and try again.") }
        guard kill(pid, SIGTERM) == 0 || errno == ESRCH else { throw RelayError.message("Could not stop the Remote runtime.") }
        for _ in 0..<100 {
            if kill(pid, 0) != 0, errno == ESRCH {
                try removeRecord(ifMatching: pid, paths: paths)
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw RelayError.message("Remote runtime is still shutting down. Try again.")
    }

    private static func verified(_ pid: Int32, paths: RelayPaths) -> Bool {
        let probe = Process(), output = Pipe()
        probe.executableURL = URL(fileURLWithPath: "/bin/ps")
        probe.arguments = ["-ww", "-p", String(pid), "-o", "uid=,command="]
        probe.standardOutput = output; probe.standardError = FileHandle.nullDevice
        guard (try? probe.run()) != nil else { return false }
        let command = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        probe.waitUntilExit()
        let fields = command.trimmingCharacters(in: .whitespacesAndNewlines).split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        let cliPaths = paths.cliCandidates
        return fields.count == 2 && fields[0] == String(getuid())
            && cliPaths.contains(where: { fields[1].hasPrefix($0 + " ") })
            && fields[1].contains(" app-server ")
            && fields[1].hasSuffix("--listen unix://" + paths.socket.path)
    }

    private static func removeRecord(ifMatching pid: Int32, paths: RelayPaths) throws {
        guard let record = try? String(contentsOf: paths.runtimePID, encoding: .utf8),
              Int32(record.trimmingCharacters(in: .whitespacesAndNewlines)) == pid else { return }
        try FileManager.default.removeItem(at: paths.runtimePID)
    }
}
