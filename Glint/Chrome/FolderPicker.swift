import AppKit

enum FolderPicker {
    @MainActor
    static func pickProjectFolder() async -> URL? {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose Project Folder")
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Select the project folder Devin should work in.")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.resolvesAliases = true

        return await withCheckedContinuation { continuation in
            panel.begin { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }
}
