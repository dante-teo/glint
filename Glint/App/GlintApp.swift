import SwiftUI

@main
struct GlintApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var workspaceStore: WorkspaceStore
    @StateObject private var updater: UpdaterController
    @StateObject private var usage: UsageStore

    init() {
        BundledFontRegistrar.registerBundledFonts()

        _workspaceStore = StateObject(wrappedValue: WorkspaceStore())
        _updater = StateObject(wrappedValue: UpdaterController())
        _usage = StateObject(wrappedValue: UsageStore())

        #if DEBUG
        // Dev builds run under their own defaults domain (app.glint.Glint.dev).
        // The first dev launch copies the production app's glint.* preferences
        // so it starts where production left off; after that the two domains
        // diverge independently. Must run before the language read below.
        if !UserDefaults.standard.bool(forKey: "glint.devDefaultsSeeded"),
           let prod = UserDefaults.standard.persistentDomain(forName: "app.glint.Glint") {
            for (key, value) in prod where key.hasPrefix("glint.") {
                UserDefaults.standard.set(value, forKey: key)
            }
            UserDefaults.standard.set(true, forKey: "glint.devDefaultsSeeded")
        }
        #endif

        // Crash-loop guard: if the previous launch died before going healthy,
        // roll back the setting change that most likely caused it BEFORE we
        // read any preference below — otherwise a bad sticky value (issue #15)
        // replays the same crash on every launch. Also starts journaling
        // subsequent setting changes so the next crash can be undone.
        SettingsSafety.shared.beginLaunch()

        // Apply the stored language choice BEFORE any view materializes so
        // Bundle.main picks the right .lproj at its first lookup. "system"
        // clears the override so macOS falls back to the user's OS-level
        // language. Any explicit choice writes into `AppleLanguages`,
        // which is what NSBundle reads to resolve localized strings.
        let storedRaw = UserDefaults.standard.string(forKey: "glint.preferredLanguage")
        let stored = WorkspaceStore.normalizedPreferredLanguage(storedRaw)
        if stored != storedRaw {
            UserDefaults.standard.set(stored, forKey: "glint.preferredLanguage")
        }
        if stored == "system" {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([stored], forKey: "AppleLanguages")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(workspaceStore)
                .environmentObject(updater)
                .environmentObject(usage)
                .frame(minWidth: 980, minHeight: 600)
                .preferredColorScheme(workspaceStore.appearanceMode.preferredColorScheme)
                // Live language switching: AppleLanguages (set in init) only
                // applies on the next launch; this env value re-resolves
                // LocalizedStringKey lookups immediately when the user picks
                // a language in Settings.
                .environment(\.locale, workspaceStore.preferredLocale)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            // Shortcut policy: a terminal app must leave the terminal's own
            // vocabulary alone. ⌘↑/⌘↓ (prompt-mark jumps) and ⌘F (future
            // scrollback search) deliberately have NO menu bindings so the
            // events reach ghostty; workspace switching uses the tab-like
            // ⌘⇧[ / ⌘⇧] plus ⌘1…⌘9 direct jumps instead.
            CommandGroup(replacing: .newItem) {
                Button(AppCommandRegistry.command(.newWorkspace).title) {
                    AppCommandRegistry.execute(.newWorkspace, in: workspaceStore)
                }
                    .keyboardShortcut("n", modifiers: .command)
                Button(AppCommandRegistry.command(.nextWorkspace).title) {
                    AppCommandRegistry.execute(.nextWorkspace, in: workspaceStore)
                }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Button(AppCommandRegistry.command(.previousWorkspace).title) {
                    AppCommandRegistry.execute(.previousWorkspace, in: workspaceStore)
                }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                ForEach(1..<10, id: \.self) { n in
                    Button("Workspace \(n)") { workspaceStore.selectWorkspace(at: n - 1) }
                        .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
                }
                Divider()
                // Direction-explicit names; "horizontal/vertical" read
                // opposite ways in different terminals and our own palette
                // copy had it backwards. `.horizontal` = side by side.
                Button(AppCommandRegistry.command(.splitRight).title) {
                    AppCommandRegistry.execute(.splitRight, in: workspaceStore)
                }
                    .keyboardShortcut("d", modifiers: .command)
                Button(AppCommandRegistry.command(.splitDown).title) {
                    AppCommandRegistry.execute(.splitDown, in: workspaceStore)
                }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button(AppCommandRegistry.command(.closePane).title) {
                    AppCommandRegistry.execute(.closePane, in: workspaceStore)
                }
                    .keyboardShortcut("w", modifiers: .command)
                Button(AppCommandRegistry.command(.focusNextPane).title) {
                    AppCommandRegistry.execute(.focusNextPane, in: workspaceStore)
                }
                    .keyboardShortcut("]", modifiers: .command)
                Button(AppCommandRegistry.command(.focusPreviousPane).title) {
                    AppCommandRegistry.execute(.focusPreviousPane, in: workspaceStore)
                }
                    .keyboardShortcut("[", modifiers: .command)
                Divider()
                // Tabs deliberately avoid the workspace vocabulary (⌘1…9,
                // ⌘⇧[ ]) so existing muscle memory is untouched: ⌘T opens,
                // ⌘⇧W closes, and ⌃Tab / ⌃⇧Tab cycle (iTerm-compatible, and
                // not a sequence the terminal itself needs).
                Button(AppCommandRegistry.command(.newTab).title) {
                    AppCommandRegistry.execute(.newTab, in: workspaceStore)
                }
                    .keyboardShortcut("t", modifiers: .command)
                Button(AppCommandRegistry.command(.closeTab).title) {
                    AppCommandRegistry.execute(.closeTab, in: workspaceStore)
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                Button(AppCommandRegistry.command(.nextTab).title) {
                    AppCommandRegistry.execute(.nextTab, in: workspaceStore)
                }
                    .keyboardShortcut(.tab, modifiers: .control)
                Button(AppCommandRegistry.command(.previousTab).title) {
                    AppCommandRegistry.execute(.previousTab, in: workspaceStore)
                }
                    .keyboardShortcut(.tab, modifiers: [.control, .shift])
            }
            CommandGroup(after: .toolbar) {
                Button("Command Palette") {
                    workspaceStore.commandPaletteOpen.toggle()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                Button(AppCommandRegistry.command(.findInSidebar).title) {
                    AppCommandRegistry.execute(.findInSidebar, in: workspaceStore)
                }
                .keyboardShortcut("f", modifiers: [.command, .option])
            }
            // Hijack the App menu's Settings… so ⌘, opens our in-window
            // sheet instead of trying to summon a separate scene.
            CommandGroup(replacing: .appSettings) {
                Button("\(AppCommandRegistry.command(.settings).title)…") {
                    AppCommandRegistry.execute(.settings, in: workspaceStore)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
