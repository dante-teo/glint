import AppKit
import UniformTypeIdentifiers

enum ImagePicker {
    @MainActor
    static func pickImages() async -> [URL] {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Attach Images")
        panel.prompt = String(localized: "Attach")
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.png, .jpeg, .gif, .webP, .heic, .tiff, .bmp]

        return await withCheckedContinuation { continuation in
            panel.begin { response in
                continuation.resume(returning: response == .OK ? panel.urls : [])
            }
        }
    }
}
