import SwiftUI

struct NavRail: View {
    @Environment(MailStore.self) private var store
    @State private var addingAlias = false
    @State private var newAlias = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 38) // traffic lights
            brand
                .padding(.horizontal, 6)
                .padding(.bottom, 16)
            HStack(spacing: 8) {
                PillButton(title: "New message", symbol: "square.and.pencil", style: .primary, expand: true) { store.newMessage() }
                IconButton(symbol: "command", help: "Search or ask Claude (⌘K)", size: 30) { store.showPalette = true }
                    .panel(radius: 9, fill: Theme.raised)
            }
            .padding(.bottom, 18)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    NavItem(title: "Dashboard", symbol: "square.grid.2x2", item: .dashboard, badge: store.dashboard.needsReply.count)
                    sectionLabel("Mailboxes")
                    ForEach(store.mailboxFolders) { f in
                        folderItem(f)
                        if f.role == .inbox {
                            NavItem(title: "Flagged", symbol: "flag", item: .flagged, badge: store.flaggedCount, quietBadge: true)
                        }
                    }
                    HStack {
                        sectionLabel("Addresses")
                        Spacer()
                        Button { addingAlias = true } label: {
                            Image(systemName: "plus").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.text3)
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 14)
                        .help("Add an alias")
                        .popover(isPresented: $addingAlias, arrowEdge: .trailing) { aliasPopover }
                    }
                    ForEach(store.addresses) { a in
                        NavItem(title: a.email, symbol: a.isPrimary ? "person.crop.circle" : "at", item: .address(a.email), badge: a.unread, quietBadge: true, mono: true)
                            .contextMenu {
                                Button("New Message from This Address") { store.newMessage(from: a.email) }
                                Button("Copy Address") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(a.email, forType: .string)
                                }
                                if !a.isPrimary {
                                    Divider()
                                    Button("Hide Alias") { store.setAlias(a.email, hidden: true) }
                                }
                            }
                    }
                    if !store.customFolders.isEmpty {
                        sectionLabel("Folders")
                        ForEach(store.customFolders) { folderItem($0) }
                    }
                }
                .padding(.bottom, 12)
            }

            ClaudeStatusCard()
                .padding(.bottom, 10)
            AccountRow()
                .padding(.bottom, 12)
        }
        .padding(.horizontal, 12)
        .background(Theme.rail)
    }

    private var brand: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.ink)
                Image(systemName: "envelope").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.onInk)
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text("Letterbox").font(Theme.serif(16, .semibold)).foregroundStyle(Theme.text)
                Text("with Claude").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.text3)
            }
            Spacer()
        }
    }

    private func sectionLabel(_ s: String) -> some View {
        Text(s).microLabel().padding(.leading, 10).padding(.top, 16).padding(.bottom, 5)
    }

    private func folderItem(_ f: Folder) -> some View {
        let badge: Int = switch f.role {
        case .inbox, .archive, .custom: f.unread
        case .drafts: f.total
        default: 0
        }
        return NavItem(title: f.displayName, symbol: f.role.symbol, item: .folder(f.path), badge: badge, quietBadge: f.role != .inbox)
            .dropDestination(for: String.self) { ids, _ in
                store.move(ids, to: f.path)
                return true
            }
    }

    private var aliasPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add an alias").font(.headline)
            Text("Letterbox detects aliases from your mail automatically. Add one here if it hasn’t received anything yet.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("alias@example.com", text: $newAlias).textFieldStyle(.roundedBorder).onSubmit(commitAlias)
            HStack {
                Spacer()
                Button("Cancel") { addingAlias = false }
                Button("Add", action: commitAlias).keyboardShortcut(.defaultAction).disabled(!newAlias.contains("@"))
            }
        }
        .padding(16)
        .frame(width: 280)
    }

    private func commitAlias() {
        guard newAlias.contains("@") else { return }
        store.addAlias(newAlias)
        newAlias = ""
        addingAlias = false
    }
}

private struct NavItem: View {
    @Environment(MailStore.self) private var store
    let title: String
    let symbol: String
    let item: SidebarItem
    var badge = 0
    var quietBadge = false
    var ai = false
    var mono = false
    @State private var hovering = false

    private var selected: Bool { store.sidebarSelection == item && store.searchText.isEmpty }

    var body: some View {
        Button {
            store.searchText = ""
            store.sidebarSelection = item
        } label: {
            HStack(spacing: 10) {
                Group {
                    if ai {
                        Image(systemName: symbol).foregroundStyle(Theme.aurora)
                    } else {
                        Image(systemName: selected && symbol != "at" ? symbol + ".fill" : symbol)
                            .foregroundStyle(selected ? Theme.accentText : Theme.text2)
                    }
                }
                .font(.system(size: 13, weight: .medium))
                .frame(width: 18)
                Text(title)
                    .font(.system(size: mono ? 12.5 : 13, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Theme.text : Theme.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 10.5, weight: .bold).monospacedDigit())
                        .foregroundStyle(quietBadge ? Theme.text3 : Theme.text)
                        .padding(.horizontal, quietBadge ? 2 : 7)
                        .frame(minWidth: 20, minHeight: 18)
                        .background {
                            if !quietBadge {
                                Capsule().fill(Theme.accentSoft)
                            }
                        }
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(selected ? Theme.accentSoft : (hovering ? Theme.hover : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct ClaudeStatusCard: View {
    @Environment(MailStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                SparkleIcon(size: 11)
                Text("Claude").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.text)
                Spacer()
                Circle().fill(dotColor).frame(width: 6, height: 6)
            }
            Text(statusText)
                .font(.system(size: 11))
                .foregroundStyle(Theme.text2)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if store.aiStatus.isWorking { ThinkingBar() }
        }
        .padding(11)
        .aurora(radius: 11, animated: store.aiStatus.isWorking)
        .onTapGesture {
            if store.aiStatus == .missing || store.aiStatus == .off {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        }
    }

    private var dotColor: Color {
        switch store.aiStatus {
        case .ready: return Theme.success
        case .working: return Theme.high
        case .failed, .missing: return Theme.urgent
        default: return Theme.text3
        }
    }

    private var statusText: String {
        switch store.aiStatus {
        case .unknown: return "Connecting…"
        case .off: return "Turned off in Settings"
        case .missing: return "Claude CLI not found. Click to set it up."
        case .ready: return "Ready · \(store.aiModel.capitalized) · \(store.insights.count) analyzed"
        case .working(let s): return s
        case .failed(let s): return s
        }
    }
}

private struct AccountRow: View {
    @Environment(MailStore.self) private var store

    var body: some View {
        HStack(spacing: 10) {
            AvatarView(name: store.account?.displayName ?? "", email: store.account?.email ?? "", size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(store.account?.displayName.isEmpty == false ? store.account!.displayName : (store.account?.email ?? ""))
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                syncLine
            }
            Spacer(minLength: 0)
            SettingsLink {
                Image(systemName: "gearshape").font(.system(size: 13)).foregroundStyle(Theme.text3).frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help("Settings (⌘,)")
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder private var syncLine: some View {
        Group {
            if store.isSyncing {
                Text(store.syncProgress ?? "Syncing…")
            } else if let error = store.syncError {
                Text(error).foregroundStyle(Theme.urgent).help(error)
            } else if let last = store.lastSync {
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text(Date().timeIntervalSince(last) < 60 ? "Synced just now" : "Synced \(last.formatted(.relative(presentation: .named)))")
                }
            } else {
                Text("Connecting…")
            }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(Theme.text3)
        .lineLimit(1)
    }
}
