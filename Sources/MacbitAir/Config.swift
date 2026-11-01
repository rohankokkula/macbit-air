import Foundation

/// OAuth client credentials. Google "Desktop app" clients ship a client secret that is
/// not actually secret (Google's docs say so), but we still keep it out of source control.
/// File: ~/Library/Application Support/MacbitAir/config.json
///   { "clientId": "...apps.googleusercontent.com", "clientSecret": "GOCSPX-..." }
struct AppConfig: Codable {
    var clientId: String
    var clientSecret: String

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacbitAir", isDirectory: true)
    }

    static var fileURL: URL { directory.appendingPathComponent("config.json") }

    static func load() -> AppConfig? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(AppConfig.self, from: data)
    }

    /// Creates the folder and a template file so the user only has to paste values in.
    static func ensureTemplate() {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        guard !fm.fileExists(atPath: fileURL.path) else { return }
        let template = """
        {
          "clientId": "PASTE_CLIENT_ID.apps.googleusercontent.com",
          "clientSecret": "PASTE_CLIENT_SECRET"
        }
        """
        try? template.data(using: .utf8)?.write(to: fileURL)
    }

    var isFilledIn: Bool { !clientId.hasPrefix("PASTE_") && !clientSecret.hasPrefix("PASTE_") }
}
