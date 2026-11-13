import AppKit

/// Multi-select folder picker shared by the scan-root editors.
enum DirectoryPicker {
    static func chooseDirectories(title: String, prompt: String,
                                  startingAt directory: URL? = nil) -> [URL]? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.title = title
        panel.prompt = prompt
        if let directory { panel.directoryURL = directory }
        guard panel.runModal() == .OK else { return nil }
        return panel.urls
    }
}