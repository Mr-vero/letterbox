import SwiftUI

enum ListFilter: String, CaseIterable, Identifiable {
    case all = "All", unread = "Unread", important = "Important"
    var id: String { rawValue }
}

struct MessageListPane: View {
    @Environment(MailStore.self) private var store
    @State private var filter: ListFilter = .all
    @State private var anchor: String?
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool

    private var rows: [MessageSummary] {
        filter == .important ? store.messages.filter { (store.insights[$0.id]?.priority ?? 0) >= 2 } : store.messages
    }

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            header
            VStack(spacing: 10) {
                SearchField(text: $store.searchText, prompt: "Search all mail", focus: $searchFocused)
                FilterBar(selection: $filter)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            if rows.isEmpty { emptyState } else { list }
        }
        .background(Theme.panel)
        .onChange(of: filter) { _, f in store.unreadOnly = f == .unread }
        .onChange(of: store.searchFocusRequest) { _, _ in searchFocused = true }
        .onChange(of: store.sidebarSelection) { _, _ in if filter == .important { filter = .all } }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.title)
                    .font(Theme.display(22, .bold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(store.subtitle).font(.system(size: 12)).foregroundStyle(Theme.text3)
            }
            Spacer()
            IconButton(symbol: "arrow.clockwise", help: "Check for new mail (⇧⌘N)") { store.refresh() }
                .rotationEffect(.degrees(store.isSyncing ? 360 : 0))
                .animation(store.isSyncing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: store.isSyncing)
        }
        .padding(.horizontal, 18)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(rows) { m in
                        MessageCard(
                            message: m,
                            insight: store.insights[m.id],
                            selected: store.selection.contains(m.id),
                            alias: store.receivingAlias(for: m),
                            folderName: store.currentFolder == nil || !store.searchText.isEmpty ? store.folders.first { $0.path == m.folder }?.displayName : nil,
                            outgoing: store.currentFolder.map { $0.role == .sent || $0.role == .drafts } ?? false
                        )
                        .id(m.id)
                        .onTapGesture { click(m) }
                        .draggable(m.id)
                        .contextMenu { MessageContextMenu(ids: menuIDs(for: m), single: m) }
                    }
                }
                .padding(8)
            }
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
            .onKeyPress(phases: .down) { press in handleKey(press, proxy: proxy) }
            .onChange(of: store.selection) { _, sel in
                if sel.count == 1, let id = sel.first {
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
                }
            }
        }
    }

    private func menuIDs(for m: MessageSummary) -> [String] {
        store.selection.contains(m.id) ? Array(store.selection) : [m.id]
    }

    private func click(_ m: MessageSummary) {
        listFocused = true
        let mods = NSEvent.modifierFlags
        if mods.contains(.command) {
            if store.selection.contains(m.id) { store.selection.remove(m.id) } else { store.selection.insert(m.id) }
            anchor = m.id
        } else if mods.contains(.shift), let a = anchor, let i = rows.firstIndex(where: { $0.id == a }), let j = rows.firstIndex(where: { $0.id == m.id }) {
            store.selection = Set(rows[min(i, j)...max(i, j)].map(\.id))
        } else {
            store.selection = [m.id]
            anchor = m.id
        }
    }

    private func moveSelection(down: Bool, extend: Bool) {
        let current = rows.firstIndex { $0.id == anchor && store.selection.contains($0.id) } ?? rows.firstIndex { store.selection.contains($0.id) }
        let next = current.map { down ? min($0 + 1, rows.count - 1) : max($0 - 1, 0) } ?? 0
        guard rows.indices.contains(next) else { return }
        if extend { store.selection.insert(rows[next].id) } else { store.selection = [rows[next].id] }
        anchor = rows[next].id
    }

    private func handleKey(_ press: KeyPress, proxy: ScrollViewProxy) -> KeyPress.Result {
        let ids = Array(store.selection)
        switch press.key {
        case .downArrow, .upArrow:
            moveSelection(down: press.key == .downArrow, extend: press.modifiers.contains(.shift))
            return .handled
        case .delete, .deleteForward:
            store.trash(ids)
            return .handled
        default:
            break
        }
        guard press.modifiers.isEmpty || press.modifiers == .shift else { return .ignored }
        switch press.characters {
        case "e": store.archive(ids)
        case "#": store.trash(ids)
        case "r": store.reply(all: false)
        case "a": store.reply(all: true)
        case "f": store.forward()
        case "s": store.toggleFlag(ids)
        case "u": store.toggleRead(ids)
        case "d": if let m = store.openedMessage { store.draftWithClaude(m) }
        case "j": moveSelection(down: true, extend: false)
        case "k": moveSelection(down: false, extend: false)
        default: return .ignored
        }
        return .handled
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            if !store.searchText.isEmpty {
                emptyIcon("magnifyingglass")
                Text("No results for “\(store.searchText)”").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                Text("Try different words, or ask Claude with ⌘K.").font(.system(size: 12)).foregroundStyle(Theme.text3)
            } else if store.isSyncing && store.syncProgress != nil {
                ProgressView().controlSize(.small)
                Text(store.syncProgress ?? "").font(.system(size: 12)).foregroundStyle(Theme.text3)
            } else if filter == .important {
                emptyIcon("sparkle")
                Text("Nothing important here").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                Text("Claude hasn’t flagged anything in this mailbox.").font(.system(size: 12)).foregroundStyle(Theme.text3)
            } else {
                emptyIcon("checkmark")
                Text(filter == .unread ? "No unread mail" : "All clear").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                Text("New mail will show up here.").font(.system(size: 12)).foregroundStyle(Theme.text3)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func emptyIcon(_ s: String) -> some View {
        Image(systemName: s)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(Theme.accentText)
            .frame(width: 46, height: 46)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.accentSoft))
    }
}

struct FilterBar: View {
    @Binding var selection: ListFilter
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ListFilter.allCases) { f in
                Button {
                    withAnimation(.snappy(duration: 0.2)) { selection = f }
                } label: {
                    HStack(spacing: 5) {
                        if f == .important { SparkleIcon(size: 9.5) }
                        Text(f.rawValue)
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selection == f ? Theme.text : Theme.text3)
                    .frame(maxWidth: .infinity)
                    .frame(height: 26)
                    .background {
                        if selection == f {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Theme.raised)
                                .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                                .matchedGeometryEffect(id: "seg", in: ns)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.sunken))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

struct MessageCard: View {
    let message: MessageSummary
    let insight: Insight?
    let selected: Bool
    var alias: String?
    var folderName: String?
    var outgoing = false
    @State private var hovering = false

    private var title: String {
        guard outgoing else { return message.senderDisplay }
        let names = message.to.map { $0.name.isEmpty ? $0.email : $0.name }
        return names.isEmpty ? "No recipients" : "To " + names.joined(separator: ", ")
    }

    var body: some View {
        let unread = !message.seen
        HStack(alignment: .top, spacing: 11) {
            AvatarView(name: outgoing ? (message.to.first?.name ?? "") : message.fromName,
                       email: outgoing ? (message.to.first?.email ?? "") : message.fromEmail,
                       size: 36, ring: unread ? Theme.accent : nil)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 13.5, weight: unread ? .bold : .medium))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if message.hasAttachments { Image(systemName: "paperclip").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.text3) }
                    if message.flagged { Image(systemName: "flag.fill").font(.system(size: 9.5)).foregroundStyle(Theme.text2) }
                    if message.answered { Image(systemName: "arrowshape.turn.up.left.fill").font(.system(size: 9)).foregroundStyle(Theme.text3) }
                    Text(RelativeDate.short(message.date))
                        .font(.system(size: 11.5, weight: unread ? .semibold : .regular).monospacedDigit())
                        .foregroundStyle(Theme.text3)
                }
                Text(message.displaySubject)
                    .font(.system(size: 13, weight: unread ? .semibold : .regular))
                    .foregroundStyle(unread ? Theme.text : Theme.text2)
                    .lineLimit(1)
                if let insight, !insight.summary.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        SparkleIcon(size: 9)
                        Text(insight.summary).font(.system(size: 12)).foregroundStyle(Theme.text2).lineLimit(2)
                    }
                } else if !message.snippet.isEmpty {
                    Text(message.snippet).font(.system(size: 12)).foregroundStyle(Theme.text3).lineLimit(2)
                }
                chips
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? Theme.accentSoft : (hovering ? Theme.hover : .clear)))

        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var chips: some View {
        let status = insight.flatMap { $0.done ? nil : statusChip($0) }
        if status != nil || alias != nil || folderName != nil {
            HStack(spacing: 5) {
                if let status { TagChip(text: status.0, color: status.1) }
                if let alias { TagChip(text: alias, symbol: "at") }
                if let folderName { TagChip(text: folderName, symbol: "folder") }
            }
            .padding(.top, 3)
        }
    }

    private func statusChip(_ i: Insight) -> (String, Color)? {
        if i.priority >= 3 && i.status != "resolved" { return ("Urgent · \(i.statusLabel.lowercased())", Theme.urgent) }
        if i.status == "waiting" { return ("Waiting on them", Theme.text2) }
        if let due = i.dueDay, i.status != "resolved" { return (ConversationRow.dueText(due), due < Date() ? Theme.urgent : Theme.text2) }
        switch i.status {
        case "needs_reply": return ("Needs reply", Theme.text)
        case "waiting": return ("Waiting on them", Theme.text2)
        case "action": return ("To do", Theme.text)
        default: return nil
        }
    }
}

struct MessageContextMenu: View {
    @Environment(MailStore.self) private var store
    let ids: [String]
    let single: MessageSummary

    var body: some View {
        if ids.count == 1 {
            Button("Reply") { store.selection = [single.id]; store.reply(all: false, to: single) }
            Button("Reply All") { store.selection = [single.id]; store.reply(all: true, to: single) }
            Button("Draft Reply with Claude") { store.draftWithClaude(single) }
            Divider()
        }
        Button("Mark as Read / Unread") { store.toggleRead(ids) }
        Button("Flag / Unflag") { store.toggleFlag(ids) }
        Divider()
        Button("Archive") { store.archive(ids) }
        Menu("Move To") {
            ForEach(store.folders) { f in Button(f.displayName) { store.move(ids, to: f.path) } }
        }
        Button("Junk / Not Junk") { store.markJunk(ids) }
        Divider()
        Button("Move to Trash", role: .destructive) { store.trash(ids) }
    }
}
