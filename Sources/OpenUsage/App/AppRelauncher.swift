import AppKit

/// Quits and reopens the app — used to apply configuration that decides the widget registry (Crypto
/// Prices' coin list), which is built once at launch.
///
/// The new copy must start only after this one has exited: the single-instance lock would otherwise
/// make it bow out immediately. A detached shell waits for our PID to disappear, then `open`s the
/// bundle; this process terminates normally right after spawning it.
@MainActor
enum AppRelauncher {
    enum Failure: Error, LocalizedError {
        case notBundled
        case spawnFailed(String)

        var errorDescription: String? {
            switch self {
            case .notBundled:
                return "Saved. Quit and reopen OpenUsage to apply the change."
            case .spawnFailed:
                return "Saved, but OpenUsage couldn't restart itself. Quit and reopen it to apply the change."
            }
        }
    }

    static func relaunch() throws {
        let bundleURL = Bundle.main.bundleURL
        // `swift run` executes a bare binary with no .app to reopen.
        guard bundleURL.pathExtension == "app" else { throw Failure.notBundled }
        let pid = ProcessInfo.processInfo.processIdentifier
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"",
            bundleURL.path,
        ]
        do {
            try process.run()
        } catch {
            AppLog.error(.lifecycle, "relaunch helper failed to start: \(error.localizedDescription)")
            throw Failure.spawnFailed(error.localizedDescription)
        }
        AppLog.info(.lifecycle, "relaunching to apply configuration")
        NSApp.terminate(nil)
    }
}
