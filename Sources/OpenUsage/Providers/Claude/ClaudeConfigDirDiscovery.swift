import Foundation

/// Finds Claude Code's config directory when `CLAUDE_CONFIG_DIR` isn't visible to OpenUsage. Launchers
/// like cac export it only for the `claude` process, so an OpenUsage started from Finder or at login
/// never sees it, and Claude Code's login — saved under `Claude Code-credentials-<hash of that
/// directory>` — looked missing after every restart.
///
/// The directory last seen in the environment, or found here, is remembered so later launches go
/// straight to it. Applies only while the default `~/.claude` holds no login, and reads Keychain
/// attributes only, so it never shows a popup.
enum ClaudeConfigDirDiscovery {
    static let defaultsKey = "openusage.claude.configDir"

    /// Resolved once per launch, so every reader sees the same directory.
    static let discovered: String? = discover()

    static func discover(
        defaults: UserDefaults = .standard,
        home: String = NSHomeDirectory(),
        files: FileManager = .default,
        keychain: any KeychainAccessing = SecurityKeychainAccessor()
    ) -> String? {
        let baseService = "\(ClaudeAuthStore.keychainServicePrefix)-credentials"
        func hasLogin(_ directory: String) -> Bool {
            files.fileExists(atPath: directory + "/.credentials.json")
                || keychain.genericPasswordExists(
                    service: "\(baseService)-\(ClaudeAuthStore.configDirHash(directory))"
                ) == true
        }
        // A login in the default location keeps working as before.
        if files.fileExists(atPath: home + "/.claude/.credentials.json")
            || keychain.genericPasswordExists(service: baseService) == true {
            return nil
        }
        var candidates: [String] = []
        if let remembered = defaults.string(forKey: defaultsKey)?.nilIfEmpty { candidates.append(remembered) }
        // cac keeps one Claude Code home per environment and names the active one in `current`.
        let cac = home + "/.cac"
        if let current = (try? String(contentsOfFile: cac + "/current", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            candidates.append("\(cac)/envs/\(current)/.claude")
        }
        let environments = ((try? files.contentsOfDirectory(atPath: cac + "/envs")) ?? []).sorted()
        candidates += environments.map { "\(cac)/envs/\($0)/.claude" }

        guard let found = candidates.first(where: hasLogin) else { return nil }
        remember(found, defaults: defaults)
        AppLog.info(LogTag.auth("claude"), "using Claude Code's login from a config directory outside the environment")
        return found
    }

    /// Saves the directory for the next launch. A no-op when it is already the saved one.
    static func remember(_ directory: String, defaults: UserDefaults = .standard) {
        guard defaults.string(forKey: defaultsKey) != directory else { return }
        defaults.set(directory, forKey: defaultsKey)
    }
}
