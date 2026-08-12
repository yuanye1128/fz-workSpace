import Foundation

enum AIModelCatalog {
    private static let codexModelsCacheURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".codex/models_cache.json")
    private static let codexConfigURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".codex/config.toml")
    private static let claudeSettingsURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".claude/settings.json")

    private static let claudeEfforts = ["low", "medium", "high", "xhigh", "max"]
    private static let cursorEfforts = ["low", "medium", "high"]

    static func loadModels(for provider: AIProvider) async -> [AIModelOption] {
        switch provider {
        case .codex:
            return loadCodexModels()
        case .cursor:
            return await loadCursorModels()
        case .claude:
            return loadClaudeModels()
        }
    }

    static func preferredModel(from models: [AIModelOption], provider: AIProvider) -> AIModelOption? {
        guard !models.isEmpty else { return nil }
        let preferredSlug: String?
        switch provider {
        case .codex:
            preferredSlug = tomlStringValue(named: "model", in: codexConfigURL)
        case .claude:
            preferredSlug = claudeConfiguredModel()
        case .cursor:
            preferredSlug = nil
        }
        if let preferredSlug,
           let match = models.first(where: { $0.slug == preferredSlug }) {
            return match
        }
        return models.first
    }

    static func preferredEffort(for model: AIModelOption?, provider: AIProvider) -> String? {
        guard let model, model.supportsReasoning else { return nil }
        let configured: String?
        switch provider {
        case .codex:
            configured = tomlStringValue(named: "model_reasoning_effort", in: codexConfigURL)
        case .claude:
            configured = claudeConfiguredEffort()
        case .cursor:
            configured = nil
        }
        if let configured, model.reasoningLevels.contains(configured) {
            return configured
        }
        if let defaultReasoning = model.defaultReasoning,
           model.reasoningLevels.contains(defaultReasoning) {
            return defaultReasoning
        }
        return model.reasoningLevels.first
    }

    private static func loadCodexModels() -> [AIModelOption] {
        var options: [AIModelOption] = []
        if let data = try? Data(contentsOf: codexModelsCacheURL),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let models = root["models"] as? [[String: Any]] {
            for model in models {
                let visibility = (model["visibility"] as? String)?.lowercased() ?? "list"
                guard visibility == "list" else { continue }
                guard let slug = model["slug"] as? String, !slug.isEmpty else { continue }
                let displayName = (model["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? slug
                let levels = ((model["supported_reasoning_levels"] as? [[String: Any]]) ?? [])
                    .compactMap { $0["effort"] as? String }
                    .filter { !$0.isEmpty }
                let defaultReasoning = model["default_reasoning_level"] as? String
                options.append(
                    AIModelOption(
                        slug: slug,
                        displayName: displayName,
                        reasoningLevels: levels,
                        defaultReasoning: defaultReasoning
                    )
                )
            }
        }

        if let configured = tomlStringValue(named: "model", in: codexConfigURL),
           !configured.isEmpty,
           !options.contains(where: { $0.slug == configured }) {
            options.insert(
                AIModelOption(
                    slug: configured,
                    displayName: configured,
                    reasoningLevels: ["low", "medium", "high", "xhigh", "max"],
                    defaultReasoning: tomlStringValue(named: "model_reasoning_effort", in: codexConfigURL) ?? "medium"
                ),
                at: 0
            )
        }

        if options.isEmpty {
            options = [
                AIModelOption(slug: "gpt-5.6-sol", displayName: "GPT-5.6-Sol", reasoningLevels: ["low", "medium", "high", "xhigh", "max"], defaultReasoning: "medium"),
                AIModelOption(slug: "gpt-5.6-terra", displayName: "GPT-5.6-Terra", reasoningLevels: ["low", "medium", "high", "xhigh", "max"], defaultReasoning: "medium")
            ]
        }
        return options
    }

    private static func loadClaudeModels() -> [AIModelOption] {
        var slugs: [String] = []
        if let data = try? Data(contentsOf: claudeSettingsURL),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let env = root["env"] as? [String: Any] {
            let keys = [
                "ANTHROPIC_MODEL",
                "ANTHROPIC_DEFAULT_OPUS_MODEL",
                "ANTHROPIC_DEFAULT_SONNET_MODEL",
                "ANTHROPIC_DEFAULT_HAIKU_MODEL"
            ]
            for key in keys {
                if let value = env[key] as? String {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty, !slugs.contains(trimmed) {
                        slugs.append(trimmed)
                    }
                }
            }
        }
        if slugs.isEmpty {
            slugs = ["claude-opus-5", "claude-sonnet-5", "claude-sonnet-4-6"]
        }
        let defaultEffort = claudeConfiguredEffort() ?? "high"
        return slugs.map {
            AIModelOption(
                slug: $0,
                displayName: $0,
                reasoningLevels: claudeEfforts,
                defaultReasoning: defaultEffort
            )
        }
    }

    private static func loadCursorModels() async -> [AIModelOption] {
        let output = await runCommand(["cursor-agent", "--list-models"])
        let slugs = parseCursorModelList(output)
        if slugs.isEmpty {
            return []
        }
        return slugs.map {
            AIModelOption(
                slug: $0,
                displayName: $0,
                reasoningLevels: cursorEfforts,
                defaultReasoning: "medium"
            )
        }
    }

    private static func parseCursorModelList(_ output: String) -> [String] {
        var models: [String] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.lowercased().contains("failed") || trimmed.lowercased().contains("error") {
                continue
            }
            let token = trimmed
                .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "|" })
                .map(String.init)
                .first { candidate in
                    let lower = candidate.lowercased()
                    return lower.contains("gpt")
                        || lower.contains("claude")
                        || lower.contains("sonnet")
                        || lower.contains("opus")
                        || lower.contains("composer")
                        || lower.contains("cursor")
                }
            if let token, !models.contains(token) {
                models.append(token)
            } else if !trimmed.contains(" "),
                      trimmed.count > 2,
                      !trimmed.hasSuffix(":"),
                      !models.contains(trimmed) {
                models.append(trimmed)
            }
        }
        return models
    }

    private static func claudeConfiguredModel() -> String? {
        guard let data = try? Data(contentsOf: claudeSettingsURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let env = root["env"] as? [String: Any],
              let model = env["ANTHROPIC_MODEL"] as? String else { return nil }
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func claudeConfiguredEffort() -> String? {
        guard let data = try? Data(contentsOf: claudeSettingsURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let effort = root["effortLevel"] as? String else { return nil }
        let trimmed = effort.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func tomlStringValue(named key: String, in url: URL) -> String? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let pattern = #"^\s*"# + NSRegularExpression.escapedPattern(for: key) + #"\s*=\s*"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return nil }
        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        guard let match = regex.firstMatch(in: content, options: [], range: range),
              let valueRange = Range(match.range(at: 1), in: content) else { return nil }
        return String(content[valueRange])
    }

    private static func runCommand(_ arguments: [String]) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                    process.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
                } catch {
                    continuation.resume(returning: "")
                }
            }
        }
    }
}
