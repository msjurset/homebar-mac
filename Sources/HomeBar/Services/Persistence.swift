import Foundation

actor Persistence {
    static let shared = Persistence()

    let baseURL: URL
    private let configFile: URL
    private let pinsFile: URL
    private let recentsFile: URL
    private let countsFile: URL
    private let aliasesFile: URL
    private let automationOverridesFile: URL

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        let base = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".homebar")
        self.baseURL = base
        self.configFile = base.appendingPathComponent("config.json")
        self.pinsFile = base.appendingPathComponent("pins.json")
        self.recentsFile = base.appendingPathComponent("recents.json")
        self.countsFile = base.appendingPathComponent("counts.json")
        self.aliasesFile = base.appendingPathComponent("aliases.json")
        self.automationOverridesFile = base.appendingPathComponent("automation-overrides.json")

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = enc

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec

        if !FileManager.default.fileExists(atPath: base.path) {
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        }
    }

    func loadConfig() -> HAConfig {
        guard let data = try? Data(contentsOf: configFile),
              let cfg = try? decoder.decode(HAConfig.self, from: data) else {
            return .empty
        }
        return cfg
    }

    func saveConfig(_ cfg: HAConfig) throws {
        let data = try encoder.encode(cfg)
        try data.write(to: configFile, options: .atomic)
    }

    func loadPins() -> [String] {
        guard let data = try? Data(contentsOf: pinsFile),
              let pins = try? decoder.decode([String].self, from: data) else {
            return []
        }
        return pins
    }

    func savePins(_ pins: [String]) throws {
        let data = try encoder.encode(pins)
        try data.write(to: pinsFile, options: .atomic)
    }

    func loadRecents() -> [String] {
        guard let data = try? Data(contentsOf: recentsFile),
              let recents = try? decoder.decode([String].self, from: data) else {
            return []
        }
        return recents
    }

    func saveRecents(_ recents: [String]) throws {
        let data = try encoder.encode(recents)
        try data.write(to: recentsFile, options: .atomic)
    }

    func loadUsageCounts() -> [String: Int] {
        guard let data = try? Data(contentsOf: countsFile),
              let counts = try? decoder.decode([String: Int].self, from: data) else {
            return [:]
        }
        return counts
    }

    func saveUsageCounts(_ counts: [String: Int]) throws {
        let data = try encoder.encode(counts)
        try data.write(to: countsFile, options: .atomic)
    }

    func loadAliases() -> [String: String] {
        guard let data = try? Data(contentsOf: aliasesFile),
              let aliases = try? decoder.decode([String: String].self, from: data) else {
            return [:]
        }
        return aliases
    }

    func saveAliases(_ aliases: [String: String]) throws {
        let data = try encoder.encode(aliases)
        try data.write(to: aliasesFile, options: .atomic)
    }

    func loadAutomationOverrides() -> [String: [String]] {
        guard let data = try? Data(contentsOf: automationOverridesFile),
              let overrides = try? decoder.decode([String: [String]].self, from: data) else {
            return [:]
        }
        return overrides
    }

    func saveAutomationOverrides(_ overrides: [String: [String]]) throws {
        let data = try encoder.encode(overrides)
        try data.write(to: automationOverridesFile, options: .atomic)
    }
}
