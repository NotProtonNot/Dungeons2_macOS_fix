import Foundation

public struct CommandResult {
    public let status: Int32
    public let output: String
    public let timedOut: Bool

    public var succeeded: Bool { !timedOut && status == 0 }
}

public enum Shell {
    /// Runs a program and collects its combined output.
    ///
    /// Wine starts a `wineserver` that inherits our pipe and outlives the command, so this never
    /// waits for end-of-file: it waits for the process itself, then takes whatever output arrived.
    public static func run(_ executable: URL, _ arguments: [String], environment: [String: String] = [:],
                           timeout: TimeInterval = 120) -> CommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let lock = NSLock()
        var collected = Data()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            lock.lock()
            collected.append(chunk)
            lock.unlock()
        }

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return CommandResult(status: -1, output: error.localizedDescription, timedOut: false)
        }

        let timedOut = finished.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 5)
        }
        // Give the last buffered output a moment to arrive.
        Thread.sleep(forTimeInterval: 0.2)
        pipe.fileHandleForReading.readabilityHandler = nil

        lock.lock()
        let output = String(decoding: collected, as: UTF8.self)
        lock.unlock()
        return CommandResult(status: timedOut ? -1 : process.terminationStatus, output: output, timedOut: timedOut)
    }

    /// True when a process whose command line matches the extended regex `pattern` is running.
    public static func isProcessRunning(matching pattern: String) -> Bool {
        run(URL(fileURLWithPath: "/usr/bin/pgrep"), ["-i", "-f", pattern], timeout: 10).status == 0
    }
}

public enum Processes {
    /// Either the launcher or the actual game binary.
    public static func isGameRunning() -> Bool {
        Shell.isProcessRunning(matching: #"Dungeons(-Win64-Shipping)?\.exe"#)
    }

    /// Steam running inside Wine (CrossOver). The Mac's own Steam app has no `.exe` in its name.
    public static func isSteamRunning() -> Bool {
        Shell.isProcessRunning(matching: #"(steam|steamwebhelper|steamservice)\.exe"#)
    }

    /// Wine keeps a bottle's registry in memory while any of its programs run.
    public static func isWineServerRunning() -> Bool {
        Shell.isProcessRunning(matching: "wineserver")
    }
}
