import Foundation

/// Every on-disk location the growth loop writes, in one place so tests can
/// point the whole thing at a temp directory (`rootOverride`) and never touch
/// the user's `~/.moppet`.
enum GrowthPaths {

    static var rootOverride: URL?

    /// `~/.moppet/brain/growth/`
    static var root: URL {
        if let rootOverride { return rootOverride }
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".moppet/brain/growth", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// `~/.moppet/brain/library/` — lessons, one directory per intent.
    static var library: URL {
        if let rootOverride { return rootOverride.appendingPathComponent("library", isDirectory: true) }
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".moppet/brain/library", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func subdir(_ name: String) -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// `growth/sessions/<sessionID>/` — the evidence tree for one reflection.
    static func session(_ sessionID: String) -> URL {
        let url = subdir("sessions").appendingPathComponent(sessionID, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Per-turn outcomes, appended by the agent (used for domain statistics).
    static var outcomes: URL { subdir("outcomes") }

    /// Harness version snapshots (`versions/v7/`).
    static var versions: URL { subdir("versions") }

    static func write(_ text: String, to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func read(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }
}

/// `key: value` frontmatter between `---` fences, plus the body after it.
/// Used by memory facts, lessons and skills — one parser, one format.
enum Frontmatter {

    struct Parsed {
        var fields: [String: String] = [:]
        var body: String = ""
    }

    static func parse(_ text: String) -> Parsed {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return Parsed(fields: [:], body: text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        var fields: [String: String] = [:]
        var index = 1
        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces) == "---" { index += 1; break }
            if let colon = line.firstIndex(of: ":") {
                let key = String(line[line.startIndex..<colon])
                    .trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(line[line.index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces)
                if !key.isEmpty { fields[key] = value }
            }
            index += 1
        }
        let body = lines.dropFirst(index).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Parsed(fields: fields, body: body)
    }

    static func render(fields: [(String, String)], body: String) -> String {
        var lines = ["---"]
        for (key, value) in fields where !value.isEmpty {
            lines.append("\(key): \(value)")
        }
        lines.append("---")
        lines.append("")
        lines.append(body.trimmingCharacters(in: .whitespacesAndNewlines))
        return lines.joined(separator: "\n") + "\n"
    }

    static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    static func date(_ text: String) -> Date? {
        ISO8601DateFormatter().date(from: text)
    }
}
