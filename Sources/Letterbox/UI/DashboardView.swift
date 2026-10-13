import SwiftUI

struct DashboardView: View {
    @Environment(MailStore.self) private var store
    @State private var width: CGFloat = 0

    /// Snapshot rendering uses the bare content, since offscreen capture can't see scroll views.
    var scrollable = true
    var fixedWidth: CGFloat?

    private var effectiveWidth: CGFloat { fixedWidth ?? width }

    var body: some View {
        if scrollable {
            ZStack {
                Theme.canvas
                ScrollView { content(store.dashboard) }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        } else {
            content(store.dashboard).frame(width: fixedWidth).background(Theme.canvas)
        }
    }

    private func content(_ model: DashboardModel) -> some View {
        VStack(alignment: .leading, spacing: 30) {
            header
            BriefingSection()
            Metrics(model: model)
            if effectiveWidth > 1000 {
                HStack(alignment: .top, spacing: 36) {
                    lists(model).frame(maxWidth: .infinity)
                    sidebar(model).frame(width: 320)
                }
            } else {
                lists(model)
                sidebar(model)
            }
        }
        .padding(.horizontal, effectiveWidth > 700 ? 44 : 28)
        .padding(.top, 44)
        .padding(.bottom, 48)
        .frame(maxWidth: 1180, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        let part = h < 5 ? "Working late" : h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"
        let first = store.account?.displayName.split(separator: " ").first.map(String.init) ?? ""
        return first.isEmpty ? part : "\(part), \(first)"
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .lastTextBaseline) { titleBlock; Spacer(minLength: 16); actions }
            VStack(alignment: .leading, spacing: 14) { titleBlock; actions }
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Date().formatted(.dateTime.weekday(.wide).month(.wide).day())).microLabel()
            Text(greeting)
                .font(Theme.serif(34, .regular))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            PillButton(title: "Ask Claude", symbol: "sparkle", style: .secondary, compact: true) { store.showPalette = true }
            PillButton(title: "Clean up", symbol: "wand.and.stars", style: .secondary, compact: true) {
                store.startAsk("Suggest a clean-up: find newsletters, promotions and automated notifications in my inbox that I can archive.")
            }
            .disabled(!store.aiReady)
            PillButton(title: store.aiStatus.isWorking ? "Updating…" : "Refresh", symbol: "arrow.clockwise", style: .secondary, compact: true) {
                store.scheduleTriage(force: true)
            }
            .disabled(!store.aiReady || store.aiStatus.isWorking)
        }
    }

    @ViewBuilder
    private func lists(_ model: DashboardModel) -> some View {
        VStack(alignment: .leading, spacing: 30) {
            ConversationList(title: "Needs your reply", items: model.needsReply, mode: .reply,
                             empty: store.threadInsights.isEmpty ? emptyAnalysisText : "You’re all caught up on replies.")
            if !model.todo.isEmpty {
                ConversationList(title: "To do", items: model.todo, mode: .todo, empty: "")
            }
            ConversationList(title: "Waiting on others", items: model.waiting, mode: .waiting,
                             empty: "Nothing outstanding — no one owes you a reply.")
        }
    }

    private var emptyAnalysisText: String {
        store.aiReady ? "Claude is reading your recent conversations…" : "Connect Claude in Settings to organize your inbox."
    }

    @ViewBuilder
    private func sidebar(_ model: DashboardModel) -> some View {
        VStack(alignment: .leading, spacing: 30) {
            AgendaView(entries: model.agenda)
            if !model.low.isEmpty { LowPriority(items: model.low) }
        }
    }
}

// MARK: - Briefing

private struct BriefingSection: View {
    @Environment(MailStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch store.aiStatus {
            case .missing, .off:
                Text("Letterbox uses your Claude Code CLI to organize conversations and draft replies.")
                    .font(Theme.serif(19, .regular)).foregroundStyle(Theme.text2)
                SettingsLink { Text("Set up Claude in Settings").font(.system(size: 12.5, weight: .medium)) }
                    .foregroundStyle(Theme.accent)
            default:
                if let b = store.briefing {
                    Text(b.headline)
                        .font(Theme.serif(20, .regular))
                        .lineSpacing(4)
                        .foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    if !b.highlights.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(b.highlights.enumerated()), id: \.offset) { i, h in
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text("\(i + 1)").font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(Theme.text3).frame(width: 12)
                                    Text(h).font(.system(size: 13.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                } else {
                    Text("Claude is reading your recent conversations to put together a briefing.")
                        .font(Theme.serif(19, .regular)).foregroundStyle(Theme.text2)
                }
            }
            meta
        }
        .frame(maxWidth: 760, alignment: .leading)
    }

    private var meta: some View {
        HStack(spacing: 8) {
            SparkleIcon(size: 10)
            Group {
                if case .working(let s) = store.aiStatus {
                    Text(s)
                } else if case .failed(let s) = store.aiStatus {
                    Text(s).foregroundStyle(Theme.urgent).lineLimit(1)
                } else if let b = store.briefing {
                    TimelineView(.periodic(from: .now, by: 60)) { _ in
                        Text("Briefing by Claude · \(b.generated.formatted(.relative(presentation: .named)))")
                    }
                } else {
                    Text("Briefing by Claude")
                }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.text3)
            if store.aiStatus.isWorking { ThinkingBar().frame(width: 80) }
        }
    }
}

// MARK: - Metrics

private struct Metrics: View {
    @Environment(MailStore.self) private var store
    let model: DashboardModel

    var body: some View {
        HStack(spacing: 0) {
            metric(model.needsReply.count, "Need your reply")
            divider
            metric(model.waiting.count, "Waiting on others")
            divider
            metric(model.dueThisWeek, "Dated this week")
            divider
            metric(model.unread, "Unread conversations") {
                store.sidebarSelection = .folder(store.inbox?.path ?? "INBOX")
                store.unreadOnly = true
            }
        }
        .padding(.vertical, 16)
        .panel(radius: 12)
    }

    private var divider: some View {
        Rectangle().fill(Theme.hairline).frame(width: 1, height: 36)
    }

    private func metric(_ value: Int, _ label: String, action: (() -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(value)")
                .font(.system(size: 26, weight: .light).monospacedDigit())
                .foregroundStyle(Theme.text)
                .contentTransition(.numericText())
            Text(label).font(.system(size: 11.5)).foregroundStyle(Theme.text3).lineLimit(1)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { action?() }
        .animation(.snappy, value: value)
    }
}

// MARK: - Conversation lists

enum RowMode { case reply, todo, waiting }

private struct ConversationList: View {
    let title: String
    let items: [ConversationItem]
    let mode: RowMode
    let empty: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: title, count: items.count)
            if items.isEmpty {
                if !empty.isEmpty {
                    Text(empty).font(.system(size: 13)).foregroundStyle(Theme.text3)
                        .padding(.vertical, 14).padding(.horizontal, 16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .panel(radius: 12)
                }
            } else {
                let shown = expanded ? items : Array(items.prefix(6))
                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { idx, item in
                        ConversationRow(item: item, mode: mode)
                        if idx < shown.count - 1 { Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 58) }
                    }
                }
                .panel(radius: 12)
                if items.count > 6 {
                    Button(expanded ? "Show less" : "Show all \(items.count)") { withAnimation(.snappy) { expanded.toggle() } }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.text2)
                }
            }
        }
    }
}

struct ConversationRow: View {
    @Environment(MailStore.self) private var store
    let item: ConversationItem
    let mode: RowMode
    @State private var hovering = false

    private var c: Conversation { item.conversation }
    private var i: Insight { item.insight }

    var body: some View {
        let selected = store.selection.contains(item.message.id)
        HStack(alignment: .top, spacing: 14) {
            AvatarView(name: c.counterpart.name, email: c.counterpart.email, size: 30, ring: c.unread ? Theme.accent : nil)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(c.counterpart.display).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    if i.priority >= 3 { Text("Urgent").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.urgent) }
                    Spacer(minLength: 8)
                    Text(meta).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(metaColor)
                }
                Text(c.subject).font(.system(size: 12.5)).foregroundStyle(Theme.text3).lineLimit(1)
                Text(i.summary).font(.system(size: 13)).foregroundStyle(Theme.text).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    if !i.action.isEmpty && mode != .waiting {
                        Label(i.action, systemImage: "arrow.turn.down.right")
                            .labelStyle(TightLabel())
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.text2)
                            .lineLimit(1)
                    }
                    Text(threadLine).font(.system(size: 11.5)).foregroundStyle(Theme.text3).lineLimit(1)
                    Spacer(minLength: 8)
                    buttons
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(selected ? Theme.accentSoft : (hovering ? Theme.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { store.selection = [item.message.id] }
        .contextMenu { MessageContextMenu(ids: [item.message.id], single: item.message) }
    }

    @ViewBuilder private var buttons: some View {
        HStack(spacing: 6) {
            if hovering {
                PillButton(title: "Done", symbol: "checkmark", style: .ghost, compact: true) { store.setDone(item.message.id) }
            }
            switch mode {
            case .reply:
                PillButton(title: "Draft reply", symbol: "sparkle", style: .secondary, compact: true) { store.draftWithClaude(item.message) }
                    .disabled(!store.aiReady)
            case .waiting:
                if hovering {
                    PillButton(title: "Nudge", symbol: "sparkle", style: .secondary, compact: true) {
                        store.draftWithClaude(c.latest, instruction: "Write a short, polite follow-up nudging them about my last message.")
                    }
                    .disabled(!store.aiReady)
                }
            case .todo:
                EmptyView()
            }
        }
    }

    private var meta: String {
        switch mode {
        case .waiting:
            guard let mine = c.myLastReply else { return RelativeDate.short(c.latest.date) }
            let days = Calendar.current.dateComponents([.day], from: mine, to: Date()).day ?? 0
            return days <= 0 ? "Sent today" : "\(days)d waiting"
        default:
            if let due = i.dueDay { return Self.dueText(due) }
            return RelativeDate.short(c.latest.date)
        }
    }

    private var metaColor: Color {
        if mode != .waiting, let due = i.dueDay, due < Calendar.current.startOfDay(for: Date()).addingTimeInterval(86400 * 2) { return Theme.urgent }
        return Theme.text3
    }

    private var threadLine: String {
        var parts: [String] = []
        if c.count > 1 { parts.append("\(c.count) messages") }
        if let mine = c.myLastReply { parts.append("you replied \(Self.ago(mine))") }
        else if mode == .reply { parts.append("no reply yet") }
        return parts.joined(separator: " · ")
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        f.dateTimeStyle = .named
        return f
    }()

    static func ago(_ d: Date) -> String {
        Date().timeIntervalSince(d) < 60 ? "just now" : relative.localizedString(for: d, relativeTo: Date())
    }

    static func dueText(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Due today" }
        if cal.isDateInTomorrow(d) { return "Due tomorrow" }
        if d < cal.startOfDay(for: Date()) { return "Overdue" }
        return "Due " + d.formatted(.dateTime.weekday(.abbreviated).day())
    }
}

private struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) { configuration.icon.font(.system(size: 10)); configuration.title }
    }
}

// MARK: - Agenda

private struct AgendaView: View {
    @Environment(MailStore.self) private var store
    let entries: [AgendaEntry]

    private var groups: [(String, [AgendaEntry])] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var buckets: [(String, [AgendaEntry])] = [("Overdue", []), ("Today", []), ("Tomorrow", []), ("This week", []), ("Later", [])]
        for e in entries {
            let idx: Int
            if e.day < today { idx = 0 }
            else if cal.isDateInToday(e.day) { idx = 1 }
            else if cal.isDateInTomorrow(e.day) { idx = 2 }
            else if e.day < today.addingTimeInterval(7 * 86400) { idx = 3 }
            else { idx = 4 }
            buckets[idx].1.append(e)
        }
        return buckets.filter { !$0.1.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Timeline", subtitle: "Dates from your mail")
            if entries.isEmpty {
                Text("Deadlines and dates Claude finds in your conversations will appear here.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.text3)
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading).panel(radius: 12)
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(groups, id: \.0) { title, list in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(title).font(Theme.micro).tracking(0.6).textCase(.uppercase)
                                .foregroundStyle(title == "Overdue" ? Theme.urgent : Theme.text3)
                            ForEach(list) { e in row(e) }
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .panel(radius: 12)
            }
        }
    }

    private func row(_ e: AgendaEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Text(e.day.formatted(.dateTime.day())).font(.system(size: 15, weight: .regular).monospacedDigit()).foregroundStyle(Theme.text)
                Text(e.day.formatted(.dateTime.weekday(.abbreviated))).font(.system(size: 9.5, weight: .medium)).textCase(.uppercase).foregroundStyle(Theme.text3)
            }
            .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(e.text).font(.system(size: 13)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                Text("\(e.item.conversation.counterpart.display) · \(e.item.conversation.subject)")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.text3).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { store.selection = [e.item.message.id] }
    }
}

private struct LowPriority: View {
    @Environment(MailStore.self) private var store
    let items: [ConversationItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Low priority", count: items.count)
            VStack(alignment: .leading, spacing: 10) {
                let senders = Dictionary(grouping: items, by: { $0.conversation.counterpart.display }).sorted { $0.value.count > $1.value.count }.prefix(5)
                ForEach(Array(senders), id: \.key) { name, list in
                    HStack(spacing: 10) {
                        Text(name).font(.system(size: 12.5)).foregroundStyle(Theme.text2).lineLimit(1)
                        Spacer()
                        Text("\(list.count)").font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.text3)
                    }
                }
                PillButton(title: "Archive all", symbol: "archivebox", style: .secondary, compact: true) { store.archiveLowPriority() }
                    .padding(.top, 2)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel(radius: 12)
        }
    }
}
