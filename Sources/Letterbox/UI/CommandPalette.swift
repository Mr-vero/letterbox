import SwiftUI

struct CommandPalette: View {
    @Environment(MailStore.self) private var store
    @State private var query = ""
    @State private var highlighted = 0
    @State private var chatting = false
    @FocusState private var focused: Bool

    private var session: AskSession { store.askSession }

    private struct Item: Identifiable {
        let id: String
        let title: String
        let subtitle: String?
        let symbol: String
        let run: () -> Void
    }

    private static let suggestions = [
        "What needs my attention this week?",
        "Clean up newsletters and promotions I don’t need",
        "Who am I waiting on, and for how long?",
        "Summarize anything about invoices or payments",
    ]

    private var items: [Item] {
        var out: [Item] = []
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty && store.aiReady {
            out.append(Item(id: "ask", title: "Ask Claude: “\(q)”", subtitle: "Reads your mail to answer", symbol: "sparkle") { ask(q) })
        }
        if q.isEmpty && store.aiReady {
            out += Self.suggestions.enumerated().map { n, s in Item(id: "s\(n)", title: s, subtitle: nil, symbol: "sparkle") { ask(s) } }
        }
        let commands: [Item] = [
            Item(id: "compose", title: "New message", subtitle: "⌘N", symbol: "square.and.pencil") { close(); store.newMessage() },
            Item(id: "dash", title: "Go to Dashboard", subtitle: "⌘1", symbol: "square.grid.2x2") { close(); store.sidebarSelection = .dashboard },
            Item(id: "inbox", title: "Go to Inbox", subtitle: "⌘2", symbol: "tray") { close(); store.sidebarSelection = .folder(store.inbox?.path ?? "INBOX") },
            Item(id: "flagged", title: "Go to Flagged", subtitle: "⌘3", symbol: "flag") { close(); store.sidebarSelection = .flagged },
            Item(id: "refresh", title: "Check for new mail", subtitle: "⇧⌘N", symbol: "arrow.clockwise") { close(); store.refresh() },
            Item(id: "triage", title: "Refresh Claude insights", subtitle: nil, symbol: "wand.and.stars") { close(); store.scheduleTriage(force: true) },
            Item(id: "settings", title: "Open Settings", subtitle: "⌘,", symbol: "gearshape") {
                close(); NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            },
        ] + store.folders.filter { $0.role != .inbox }.map { f in
            Item(id: "f-\(f.path)", title: "Go to \(f.displayName)", subtitle: nil, symbol: f.role.symbol) {
                close(); store.sidebarSelection = .folder(f.path)
            }
        }
        out += q.isEmpty ? Array(commands.prefix(4)) : commands.filter { $0.title.localizedCaseInsensitiveContains(q) }
        if q.count >= 2 {
            let hits = store.repo.messages(MessageQuery(item: .dashboard, search: q, limit: 6))
            out += hits.map { m in
                Item(id: m.id, title: m.displaySubject, subtitle: "\(m.senderDisplay) · \(RelativeDate.short(m.date))", symbol: "envelope") {
                    close()
                    store.sidebarSelection = .folder(m.folder)
                    store.selection = [m.id]
                }
            }
        }
        return out
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .onTapGesture { close() }
            VStack(spacing: 0) {
                inputBar
                Rectangle().fill(Theme.hairline).frame(height: 1)
                if chatting {
                    AskChatView(session: session)
                } else {
                    resultList
                }
                Rectangle().fill(Theme.hairline).frame(height: 1)
                footer
            }
            .frame(width: chatting ? 760 : 660)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.strongLine, lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 40, y: 20)
            .padding(.top, 80)
            .animation(.snappy(duration: 0.2), value: chatting)
        }
        .onAppear {
            focused = true
            if let q = store.pendingAsk {
                store.pendingAsk = nil
                ask(q)
            } else if !session.turns.isEmpty {
                chatting = true
            }
        }
        .onKeyPress(.escape) { close(); return .handled }
        .onKeyPress(.downArrow) {
            guard !chatting else { return .ignored }
            highlighted = min(highlighted + 1, max(items.count - 1, 0)); return .handled
        }
        .onKeyPress(.upArrow) {
            guard !chatting else { return .ignored }
            highlighted = max(highlighted - 1, 0); return .handled
        }
        .onKeyPress(.return, phases: .down) { press in
            if press.modifiers.contains(.command), store.aiReady, !query.isEmpty { ask(query); return .handled }
            return .ignored
        }
    }

    private var inputBar: some View {
        HStack(spacing: 12) {
            Image(systemName: chatting ? "sparkle" : "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.text3)
            TextField(chatting ? "Ask a follow-up…" : "Search, run a command, or ask Claude anything…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .focused($focused)
                .onSubmit { chatting ? ask(query) : run() }
                .onChange(of: query) { _, _ in highlighted = 0 }
            if chatting {
                Button("New chat") {
                    session.task?.cancel()
                    session.turns = []
                    chatting = false
                    query = ""
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.text2)
            }
            Text("esc").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.text3)
                .padding(.horizontal, 6).frame(height: 18).background(RoundedRectangle(cornerRadius: 4).fill(Theme.sunken))
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if chatting {
                hint("↵", "ask")
                hint("esc", "close")
            } else {
                hint("↑↓", "navigate")
                hint("↵", "select")
                if store.aiReady { hint("⌘↵", "ask Claude") }
            }
            Spacer()
            SparkleIcon(size: 10)
            Text(store.aiReady ? "Claude \(store.aiModel.capitalized)" : "Claude offline").font(.system(size: 11)).foregroundStyle(Theme.text3)
        }
        .padding(.horizontal, 16)
        .frame(height: 32)
    }

    private var resultList: some View {
        let list = items
        return ScrollView {
            VStack(spacing: 1) {
                ForEach(Array(list.enumerated()), id: \.element.id) { i, item in
                    HStack(spacing: 12) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.text2)
                            .frame(width: 26, height: 26)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.sunken))
                        Text(item.title).font(.system(size: 13.5)).foregroundStyle(Theme.text).lineLimit(1)
                        Spacer()
                        if let s = item.subtitle { Text(s).font(.system(size: 11.5)).foregroundStyle(Theme.text3).lineLimit(1) }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 40)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(i == highlighted ? Theme.accentSoft : .clear))
                    .contentShape(Rectangle())
                    .onTapGesture { item.run() }
                    .onHover { if $0 { highlighted = i } }
                }
            }
            .padding(8)
        }
        .frame(maxHeight: 400)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(key).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.text2)
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.text3)
        }
    }

    private func run() {
        let list = items
        guard list.indices.contains(highlighted) else { return }
        list[highlighted].run()
    }

    private func ask(_ q: String) {
        let question = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !session.busy else { return }
        chatting = true
        query = ""
        store.ask(question, in: session)
    }

    private func close() {
        store.showPalette = false
    }
}

/// The assistant conversation: answers, sources, and confirmable actions.
struct AskChatView: View {
    @Environment(MailStore.self) private var store
    @Bindable var session: AskSession

    var body: some View {
        ScrollViewReader { proxy in
            MaybeScroll {
                VStack(alignment: .leading, spacing: 26) {
                    ForEach(session.turns.indices, id: \.self) { i in
                        turnView(i).id(session.turns[i].id)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 200, maxHeight: 520)
            .onChange(of: session.turns.count) { _, _ in
                if let last = session.turns.last { withAnimation { proxy.scrollTo(last.id, anchor: .top) } }
            }
        }
    }

    @ViewBuilder
    private func turnView(_ i: Int) -> some View {
        let t = session.turns[i]
        VStack(alignment: .leading, spacing: 12) {
            Text(t.question)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.text2)
            if !t.done {
                HStack(spacing: 10) {
                    ThinkingBar().frame(width: 90)
                    Text(t.stage).font(.system(size: 12)).foregroundStyle(Theme.text3)
                    Spacer()
                    Button("Stop") { session.task?.cancel() }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.text2)
                }
            }
            if let e = t.error {
                Text(e).font(.system(size: 13)).foregroundStyle(Theme.urgent)
            }
            if !t.answer.isEmpty {
                Text(t.answer)
                    .font(.system(size: 14))
                    .lineSpacing(4)
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !t.refs.isEmpty { sources(t.refs) }
            if t.action != nil { ActionCard(action: Binding(get: { session.turns[i].action! }, set: { session.turns[i].action = $0 })) }
        }
    }

    private func sources(_ refs: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sources").microLabel()
            ForEach(refs.prefix(6), id: \.self) { id in
                if let c = store.conversationByID[id] {
                    Button {
                        let m = c.latestIncoming ?? c.latest
                        store.showPalette = false
                        store.sidebarSelection = .folder(m.folder)
                        store.selection = [m.id]
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "envelope").font(.system(size: 10.5)).foregroundStyle(Theme.text3)
                            Text(c.counterpart.display).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text)
                            Text(c.subject).font(.system(size: 12)).foregroundStyle(Theme.text3).lineLimit(1)
                            Spacer()
                            Text(RelativeDate.short(c.latest.date)).font(.system(size: 11)).foregroundStyle(Theme.text3)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.sunken))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Review-and-confirm card for clean-ups Claude proposes.
struct ActionCard: View {
    @Environment(MailStore.self) private var store
    @Binding var action: ProposedAction
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: action.kind == .trash ? "trash" : action.kind == .archive ? "archivebox" : action.kind == .flag ? "flag" : "envelope.open")
                    .font(.system(size: 12)).foregroundStyle(Theme.text2)
                Text("\(action.verb) · \(action.selected.count) of \(action.conversations.count) conversations")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                Spacer()
                Button(expanded ? "Hide list" : "Review list") { withAnimation(.snappy) { expanded.toggle() } }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text2)
            }
            Text(action.summary).font(.system(size: 12.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            if expanded {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(action.conversations, id: \.self) { id in
                            if let c = store.conversationByID[id] { row(id, c) }
                        }
                    }
                }
                .frame(maxHeight: 220)
                .panel(radius: 8, fill: Theme.panel)
            }
            HStack(spacing: 8) {
                if action.executed {
                    Label("Done", systemImage: "checkmark").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.success)
                } else {
                    PillButton(title: action.verb, symbol: nil, style: .primary, compact: true) {
                        let n = store.perform(action)
                        action.executed = true
                        if action.kind == .markRead || action.kind == .flag { store.showToast("Updated \(n) messages", symbol: "checkmark") }
                    }
                    .disabled(action.selected.isEmpty)
                    PillButton(title: "Dismiss", style: .ghost, compact: true) { action.selected = []; action.executed = true }
                    if action.kind == .trash {
                        Text("Moves to Trash — you can restore from there.").font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                    }
                }
            }
        }
        .padding(14)
        .panel(radius: 10, fill: Theme.sunken)
    }

    private func row(_ id: String, _ c: Conversation) -> some View {
        let on = action.selected.contains(id)
        return HStack(spacing: 10) {
            Image(systemName: on ? "checkmark.square.fill" : "square")
                .font(.system(size: 13))
                .foregroundStyle(on ? Theme.text : Theme.text3)
            Text(c.counterpart.display).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text).frame(width: 150, alignment: .leading).lineLimit(1)
            Text(c.subject).font(.system(size: 12)).foregroundStyle(Theme.text3).lineLimit(1)
            Spacer()
            Text(RelativeDate.short(c.latest.date)).font(.system(size: 11)).foregroundStyle(Theme.text3)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !action.executed else { return }
            if on { action.selected.remove(id) } else { action.selected.insert(id) }
        }
    }
}
