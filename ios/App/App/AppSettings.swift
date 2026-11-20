import Foundation

/// Addresses of the Raid-Planner deployment. Entered on the setup page (www/index.html) or in the
/// iOS Settings app (Settings.bundle, same UserDefaults keys), so no host is baked into the build.
struct AppSettings: Equatable {
    static let appURLKey = "appUrl"
    static let authHostKey = "authHost"

    /// Origin of the web app, e.g. https://raid-planner.example.org
    let appURL: URL
    /// Host of Keycloak, e.g. keycloak.example.org; the login page may open inside the app.
    let authHost: String

    /// The stored settings, nil while nothing (valid) has been entered yet.
    static var stored: AppSettings? {
        let raw = rawStored
        return try? validated(appURL: raw.appURL, authHost: raw.authHost)
    }

    /// The stored texts as entered, also when invalid (to prefill the setup page).
    static var rawStored: (appURL: String, authHost: String) {
        let defaults = UserDefaults.standard
        return (defaults.string(forKey: appURLKey) ?? "", defaults.string(forKey: authHostKey) ?? "")
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(appURL.absoluteString, forKey: Self.appURLKey)
        defaults.set(authHost, forKey: Self.authHostKey)
    }

    enum ValidationError: LocalizedError {
        case appURL
        case authHost

        var errorDescription: String? {
            switch self {
            case .appURL:
                return "Bitte eine gültige Adresse eingeben, z. B. https://raid-planner.example.org"
            case .authHost:
                return "Bitte den Login-Server angeben, z. B. keycloak.example.org"
            }
        }
    }

    /// Normalizes user input: the scheme may be left out (https), path and query are dropped,
    /// the login server may be given as host or as URL.
    static func validated(appURL rawURL: String, authHost rawHost: String) throws -> AppSettings {
        guard let components = urlComponents(from: rawURL),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = components.host?.lowercased(), isHostName(host) else {
            throw ValidationError.appURL
        }
        var origin = URLComponents()
        origin.scheme = scheme
        origin.host = host
        origin.port = components.port
        guard let url = origin.url else {
            throw ValidationError.appURL
        }

        guard let authHost = urlComponents(from: rawHost)?.host?.lowercased(), isHostName(authHost) else {
            throw ValidationError.authHost
        }
        return AppSettings(appURL: url, authHost: authHost)
    }

    private static func urlComponents(from raw: String) -> URLComponents? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            return nil
        }
        if !text.contains("://") {
            text = "https://" + text
        }
        return URLComponents(string: text)
    }

    private static func isHostName(_ host: String) -> Bool {
        let label = "[a-z0-9]([a-z0-9-]*[a-z0-9])?"
        return host.range(of: "^\(label)(\\.\(label))*$", options: .regularExpression) != nil
    }
}
