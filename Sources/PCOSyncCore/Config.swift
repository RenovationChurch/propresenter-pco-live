// App settings (config.json) and Planning Center credentials
// (credentials.json, mode 600), both in the app's data directory:
//   macOS: ~/Library/Application Support/PCOSync/
//   other: ~/.config/pcosync/
// The web UI edits both. Credentials are never sent back to the browser.

import Foundation

public struct PCOSettings: Codable, Equatable {
    public var serviceTypeId = ""
    /// "auto" = the next plan with songs in any service type (see
    /// PCOClient.resolvePlan), "next" = the next upcoming plan in
    /// `serviceTypeId`, or a specific plan ID.
    public var plan = "auto"
    /// For "auto": only look in these service types. Empty = all of them.
    public var serviceTypeIds: [String] = []

    public init(serviceTypeId: String = "", plan: String = "auto", serviceTypeIds: [String] = []) {
        self.serviceTypeId = serviceTypeId
        self.plan = plan
        self.serviceTypeIds = serviceTypeIds
    }
}

public struct ProPresenterSettings: Codable, Equatable {
    public var host = "127.0.0.1"
    public var port = 50001
    public var timeout = 2.0
    /// How often to ask ProPresenter what's live (seconds).
    public var pollInterval = 0.5
}

public struct WebSettings: Codable, Equatable {
    public var port = 8642
    /// Listen on all network interfaces, not just this Mac. Requires a password.
    public var allowRemote = false
    public var password = ""
}

public struct AppSettings: Codable, Equatable {
    /// Start syncing when the app launches.
    public var autoStart = true
    /// Start armed (moving LIVE) when the app launches. Off = dry-run.
    public var startArmed = false
    public var logLevel = "INFO"
}

public struct AppConfig: Codable, Equatable {
    public var pco = PCOSettings()
    public var propresenter = ProPresenterSettings()
    public var sync = SyncSettings()
    public var match = MatchSettings(ignore: ["Pre-Service Loop", "Announcements Loop", "regex:^backup"])
    public var web = WebSettings()
    public var app = AppSettings()

    public init() {}

    /// Decode, filling anything missing from the defaults.
    public static func decode(_ data: Data) throws -> AppConfig {
        let defaults = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AppConfig())) as! JSONObject
        guard let user = try JSONSerialization.jsonObject(with: data) as? JSONObject else {
            throw ConfigError("config must be a JSON object")
        }
        let merged = deepMerge(defaults, user)
        return try JSONDecoder().decode(AppConfig.self, from: JSONSerialization.data(withJSONObject: merged))
    }

    /// Problems that make the settings unusable, in plain words.
    public func validate() -> [String] {
        var errs: [String] = []
        if !(1...65535).contains(propresenter.port) { errs.append("ProPresenter port must be 1-65535") }
        if propresenter.host.trimmingCharacters(in: .whitespaces).isEmpty { errs.append("ProPresenter host is empty") }
        if propresenter.pollInterval < 0.1 { errs.append("poll interval must be at least 0.1 s") }
        if propresenter.timeout <= 0 { errs.append("ProPresenter timeout must be positive") }
        if sync.maxJump < 1 { errs.append("max jump must be at least 1") }
        if sync.debounceSeconds < 0 { errs.append("debounce can't be negative") }
        if !(1024...65535).contains(web.port) { errs.append("web port must be 1024-65535") }
        if web.allowRemote && web.password.count < 6 { errs.append("remote access needs a password of 6+ characters") }
        if pco.plan.trimmingCharacters(in: .whitespaces).isEmpty { errs.append("plan must be 'auto', 'next' or a plan ID") }
        if sync.serviceLeadMinutes < 0 { errs.append("service lead time can't be negative") }
        if sync.serviceWindowMinutes < 30 { errs.append("service length must be at least 30 minutes") }
        for p in match.ignore where p.hasPrefix(regexPrefix) {
            if (try? NSRegularExpression(pattern: String(p.dropFirst(regexPrefix.count)))) == nil {
                errs.append("ignore pattern \(p) is not a valid regular expression")
            }
        }
        return errs
    }
}

public struct ConfigError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

func deepMerge(_ base: JSONObject, _ over: JSONObject) -> JSONObject {
    var out = base
    for (k, v) in over {
        if let b = base[k] as? JSONObject, let o = v as? JSONObject, k != "aliases" {
            out[k] = deepMerge(b, o)
        } else {
            out[k] = v
        }
    }
    return out
}

public struct Credentials: Codable, Equatable {
    public var appId: String
    public var secret: String

    public init(appId: String, secret: String) {
        self.appId = appId
        self.secret = secret
    }
}

public final class ConfigStore {
    public let directory: URL
    private let lock = NSLock()
    private var _config: AppConfig
    private var _credentials: Credentials?

    public var configURL: URL { directory.appendingPathComponent("config.json") }
    public var credentialsURL: URL { directory.appendingPathComponent("credentials.json") }

    /// Development override: PCO_BASE_URL points the app at tools/mock_servers.py.
    public let pcoBaseURLOverride = ProcessInfo.processInfo.environment["PCO_BASE_URL"]

    public static func defaultDirectory() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #if os(macOS)
        return home.appendingPathComponent("Library/Application Support/PCOSync", isDirectory: true)
        #else
        return home.appendingPathComponent(".config/pcosync", isDirectory: true)
        #endif
    }

    public init(directory: URL = ConfigStore.defaultDirectory()) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        if let data = try? Data(contentsOf: directory.appendingPathComponent("config.json")) {
            _config = try AppConfig.decode(data)
        } else {
            _config = AppConfig()
        }
        if let data = try? Data(contentsOf: directory.appendingPathComponent("credentials.json")) {
            _credentials = try? JSONDecoder().decode(Credentials.self, from: data)
        }
    }

    public var config: AppConfig {
        lock.lock(); defer { lock.unlock() }
        return _config
    }

    /// Credentials from the environment (PCO_APP_ID / PCO_SECRET) win over the file.
    public var credentials: Credentials? {
        let env = ProcessInfo.processInfo.environment
        if let a = env["PCO_APP_ID"], let s = env["PCO_SECRET"], !a.isEmpty, !s.isEmpty {
            return Credentials(appId: a, secret: s)
        }
        lock.lock(); defer { lock.unlock() }
        return _credentials
    }

    public func save(_ config: AppConfig) throws {
        let errs = config.validate()
        if !errs.isEmpty { throw ConfigError(errs.joined(separator: "; ")) }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try write(enc.encode(config), to: configURL)
        lock.lock(); _config = config; lock.unlock()
    }

    public func saveCredentials(_ creds: Credentials?) throws {
        if let c = creds {
            try write(JSONEncoder().encode(c), to: credentialsURL)
        } else {
            try? FileManager.default.removeItem(at: credentialsURL)
        }
        lock.lock(); _credentials = creds; lock.unlock()
    }

    private func write(_ data: Data, to url: URL) throws {
        // Write to a private temp file then rename, so a crash never leaves a
        // half-written file and the secret is never world-readable.
        let tmp = url.appendingPathExtension("tmp")
        let fm = FileManager.default
        try? fm.removeItem(at: tmp)
        guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw ConfigError("could not write \(url.path)")
        }
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: url)
        }
    }
}
