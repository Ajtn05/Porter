import Foundation

/// Finds an `adb` binary.
///
/// The app ships its own copy in `Contents/Resources/platform-tools` so that no
/// separate platform-tools install is required. The remaining paths pick up an
/// SDK that is already present.
public enum ADBLocator {
    public static let bundledSubdirectory = "platform-tools"

    public static func locate(bundle: Bundle = .main,
                              fileManager: FileManager = .default,
                              environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        for candidate in candidatePaths(bundle: bundle, environment: environment) {
            if fileManager.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    public static func candidatePaths(bundle: Bundle = .main,
                                      environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        var candidates: [URL] = []

        // 1. The bundled copy, preferred because its version is known.
        if let resources = bundle.resourceURL {
            candidates.append(resources.appendingPathComponent("\(bundledSubdirectory)/adb"))
        }
        // 2. An SDK named by the environment.
        for key in ["ANDROID_SDK_ROOT", "ANDROID_HOME"] {
            if let root = environment[key], !root.isEmpty {
                candidates.append(URL(fileURLWithPath: root).appendingPathComponent("platform-tools/adb"))
            }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        candidates.append(home.appendingPathComponent("Library/Android/sdk/platform-tools/adb"))
        // 3. Common package-manager locations.
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/adb"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/adb"))
        // 4. Anything on PATH.
        for directory in (environment["PATH"] ?? "").split(separator: ":") where !directory.isEmpty {
            candidates.append(URL(fileURLWithPath: String(directory)).appendingPathComponent("adb"))
        }
        return candidates
    }

    public static var missingToolError: TransferError {
        .toolMissing(
            name: "adb",
            hint: "Reinstall Porter, or install Android platform-tools and set ANDROID_SDK_ROOT."
        )
    }
}
