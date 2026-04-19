import Foundation

enum OnePasswordError: LocalizedError {
    case cliNotFound
    case failed(code: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case .cliNotFound:
            return "1Password CLI (op) not found. Install via `brew install 1password-cli` and sign in."
        case .failed(let code, let message):
            return message.isEmpty ? "op exited with status \(code)" : message
        }
    }
}

enum OnePassword {
    /// Common install locations for the op CLI. PATH is not inherited by
    /// GUI-launched apps, so we search explicit paths.
    static let searchPaths = [
        "/opt/homebrew/bin/op",
        "/usr/local/bin/op",
        "/opt/1Password/op",
    ]

    static func locate() -> URL? {
        for p in searchPaths where FileManager.default.isExecutableFile(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        return nil
    }

    static func isInstalled() -> Bool { locate() != nil }

    /// Resolves an `op://vault/item[/section]/field` reference by invoking
    /// `op read`. Triggers Touch ID prompt when 1Password desktop app
    /// integration is enabled. Runs on a background thread; safe to await from
    /// MainActor without blocking the UI.
    static func resolve(_ reference: String) async throws -> String {
        try await Task.detached { () throws -> String in
            guard let opURL = locate() else { throw OnePasswordError.cliNotFound }
            let process = Process()
            process.executableURL = opURL
            process.arguments = ["read", reference]
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                let msg = (String(data: errData, encoding: .utf8) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw OnePasswordError.failed(code: process.terminationStatus, message: msg)
            }
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            return (String(data: data, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }
}
