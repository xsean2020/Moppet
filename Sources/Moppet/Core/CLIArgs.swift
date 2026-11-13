import Foundation

/// Minimal `--flag value` reader shared by the network command-line entries.
enum CLIArgs {
    static func string(_ args: [String], _ flag: String) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    static func int(_ args: [String], _ flag: String) -> Int? {
        string(args, flag).flatMap(Int.init)
    }
}