import SwiftUI

@main
struct LetterboxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = MailStore()

    var body: some Scene {
        Window("Letterbox", id: "main") {
            RootView()
                .environment(store)
        }
        .defaultSize(width: 1440, height: 900)
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .commands { MailCommands(store: store) }

        WindowGroup("New Message", id: "compose", for: UUID.self) { $id in
            if let id, let draft = store.drafts[id] {
                ComposeView(draft: draft)
                    .environment(store)
            }
        }
        .defaultSize(width: 720, height: 640)
        .windowStyle(.hiddenTitleBar)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView()
                .environment(store)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let dir = Snapshot.outputDir {
            NSApp.setActivationPolicy(.accessory)
            NSApp.windows.forEach { $0.orderOut(nil) }
            Snapshot.run(to: dir)
            return
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct MailCommands: Commands {
    let store: MailStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Message") { store.newMessage() }
                .keyboardShortcut("n")
                .disabled(store.account == nil)
        }
        CommandGroup(after: .newItem) {
            Button("Get New Mail") { store.refresh() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(store.account == nil)
        }
        CommandMenu("Message") {
            let ids = Array(store.selection)
            let none = ids.isEmpty
            Button("Reply") { store.reply(all: false) }
                .keyboardShortcut("r")
                .disabled(store.selection.count != 1)
            Button("Reply All") { store.reply(all: true) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(store.selection.count != 1)
            Button("Forward") { store.forward() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(store.selection.count != 1)
            Divider()
            Button("Archive") { store.archive(ids) }
                .keyboardShortcut("a", modifiers: [.command, .control])
                .disabled(none)
            Button("Move to Trash") { store.trash(ids) }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(none)
            Button("Junk / Not Junk") { store.markJunk(ids) }
                .keyboardShortcut("j", modifiers: [.command, .shift])
                .disabled(none)
            Divider()
            Button("Mark as Read / Unread") { store.toggleRead(ids) }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(none)
            Button("Flag / Unflag") { store.toggleFlag(ids) }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(none)
        }
        CommandMenu("Go") {
            Button("Search or Ask Claude…") { store.showPalette.toggle() }
                .keyboardShortcut("k")
            Button("Find") { store.searchFocusRequest += 1; if store.sidebarSelection == .dashboard { store.sidebarSelection = .folder(store.inbox?.path ?? "INBOX") } }
                .keyboardShortcut("f")
            Divider()
            Button("Dashboard") { store.sidebarSelection = .dashboard }
                .keyboardShortcut("1")
            Button("Inbox") { store.sidebarSelection = .folder(store.inbox?.path ?? "INBOX") }
                .keyboardShortcut("2")
            Button("Flagged") { store.sidebarSelection = .flagged }
                .keyboardShortcut("3")
            Divider()
            Button("Draft Reply with Claude") { if let m = store.openedMessage { store.draftWithClaude(m) } }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(store.openedMessage == nil || !store.aiReady)
            Button("Refresh Claude Insights") { store.scheduleTriage(force: true) }
                .disabled(!store.aiReady)
        }
        CommandGroup(after: .sidebar) {
            Button(store.unreadOnly ? "Show All Messages" : "Show Only Unread") { store.unreadOnly.toggle() }
                .keyboardShortcut("u", modifiers: [.command, .option])
        }
    }
}
