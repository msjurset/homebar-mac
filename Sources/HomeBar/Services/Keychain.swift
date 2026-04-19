import Foundation

/// Token storage. Originally used macOS Keychain, but every adhoc-signed rebuild
/// presents as a "new app" to Keychain and prompts for the login password.
/// Since the HA access token is a local HA credential on the user's own
/// machine, storing it in a 0600 file in `~/.homebar/` gives equivalent
/// practical protection without the rebuild prompt.
enum Keychain {
    private static let tokenURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".homebar")
        .appendingPathComponent("token")

    static func setToken(_ token: String) throws {
        let dir = tokenURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try token.write(to: tokenURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: tokenURL.path
        )
    }

    static func getToken() -> String? {
        guard let data = try? Data(contentsOf: tokenURL) else { return nil }
        let s = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (s?.isEmpty == false) ? s : nil
    }

    static func deleteToken() {
        try? FileManager.default.removeItem(at: tokenURL)
    }
}
