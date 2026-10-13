import SwiftUI

struct ReaderPane: View {
    @Environment(MailStore.self) private var store
    var dismissable: Bool

    var body: some View {
        VStack(spacing: 0) {
            ReaderToolbar(dismissable: dismissable)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            Group {
                if store.selection.count > 1 {
                    MultiSelectionView(count: store.selection.count)
                } else if let message = store.openedMessage {
                    MessageDetailView(message: message)
                } else {
                    EmptyReader()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.panel)
        .frame(minWidth: 440)
    }
}

private struct ReaderToolbar: View {
    @Environment(MailStore.self) private var store
    var dismissable: Bool

    var body: some View {
        let ids = Array(store.selection)
        let none = ids.isEmpty
        let single = store.openedMessage
        HStack(spacing: 4) {
            if dismissable {
                IconButton(symbol: "xmark", help: "Close") { store.selection = [] }
                Rectangle().fill(Theme.hairline).frame(width: 1, height: 18).padding(.horizontal, 4)
            }
            IconButton(symbol: "archivebox", help: "Archive (E)") { store.archive(ids) }.disabled(none)
            IconButton(symbol: "trash", help: "Move to Trash (⌫)") { store.trash(ids) }.disabled(none)
            IconButton(symbol: "xmark.bin", help: "Junk / Not Junk") { store.markJunk(ids) }.disabled(none)
            Rectangle().fill(Theme.hairline).frame(width: 1, height: 18).padding(.horizontal, 4)
            IconButton(symbol: single?.flagged == true ? "flag.fill" : "flag", help: "Flag (S)", tint: single?.flagged == true ? Theme.high : Theme.text2) { store.toggleFlag(ids) }.disabled(none)
            IconButton(symbol: single?.seen == false ? "envelope.badge.fill" : "envelope.badge", help: "Read / Unread (U)") { store.toggleRead(ids) }.disabled(none)
            Menu {
                ForEach(store.folders) { f in Button(f.displayName) { store.move(ids, to: f.path) } }
            } label: {
                Image(systemName: "folder").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text2)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 30, height: 30)
            .disabled(none)
            .help("Move to folder")
            Spacer()
            if let single {
                PillButton(title: "Reply", symbol: "arrowshape.turn.up.left", style: .secondary, compact: true) { store.reply(all: false, to: single) }
                Menu {
                    Button("Reply All") { store.reply(all: true, to: single) }
                    Button("Forward") { store.forward() }
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 22)
                DraftWithClaudeButton(message: single)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 54)
        .padding(.top, dismissable ? 0 : 0)
    }
}

struct DraftWithClaudeButton: View {
    @Environment(MailStore.self) private var store
    let message: MessageSummary
    var compact = true

    var body: some View {
        HStack(spacing: 0) {
            PillButton(title: "Draft with Claude", symbol: "sparkle", style: .ai, compact: compact) { store.draftWithClaude(message) }
            Menu {
                ForEach(ReplyTone.allCases) { tone in
                    Button(tone.rawValue) { store.draftWithClaude(message, tone: tone) }
                }
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 20)
            .help("Choose a tone")
        }
        .disabled(!store.aiReady)
        .help(store.aiReady ? "Let Claude write a reply (D)" : "Claude isn’t connected — see Settings")
    }
}

private struct EmptyReader: View {
    @Environment(MailStore.self) private var store

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.accentSoft).frame(width: 72, height: 72)
                Image(systemName: "envelope.open").font(.system(size: 26, weight: .light)).foregroundStyle(Theme.accentText)
            }
            Text("Select a message").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
            VStack(spacing: 6) {
                shortcut("↑ ↓", "Navigate")
                shortcut("E", "Archive")
                shortcut("D", "Draft reply with Claude")
                shortcut("⌘K", "Search or ask Claude")
            }
        }
    }

    private func shortcut(_ key: String, _ label: String) -> some View {
        HStack(spacing: 10) {
            Text(key).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.text2)
                .padding(.horizontal, 7).frame(minWidth: 34, minHeight: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.sunken))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.hairline))
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.text3)
            Spacer()
        }
        .frame(width: 220)
    }
}

private struct MultiSelectionView: View {
    @Environment(MailStore.self) private var store
    let count: Int

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                ForEach(0..<3) { i in
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Theme.raised)
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline))
                        .frame(width: 130, height: 90)
                        .rotationEffect(.degrees(Double(i - 1) * 7))
                        .shadow(color: .black.opacity(0.15), radius: 10, y: 5)
                }
                Text("\(count)").font(Theme.serif(32, .regular)).foregroundStyle(Theme.text)
            }
            Text("\(count) messages selected").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
            HStack(spacing: 8) {
                let ids = Array(store.selection)
                PillButton(title: "Archive", symbol: "archivebox") { store.archive(ids) }
                PillButton(title: "Mark read", symbol: "envelope.open") { store.toggleRead(ids) }
                PillButton(title: "Trash", symbol: "trash") { store.trash(ids) }
            }
        }
    }
}

struct MessageDetailView: View {
    @Environment(MailStore.self) private var store
    let message: MessageSummary
    @State private var allowRemoteFor: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(message.displaySubject)
                .font(Theme.display(23, .bold))
                .tracking(-0.3)
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 12) {
                AvatarView(name: message.fromName, email: message.fromEmail, size: 42)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(message.senderDisplay).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                        if !message.fromName.isEmpty {
                            Text(message.fromEmail).font(.system(size: 12.5)).foregroundStyle(Theme.text3)
                        }
                    }
                    .lineLimit(1)
                    .textSelection(.enabled)
                    .contextMenu {
                        Button("Copy Address") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.fromEmail, forType: .string)
                        }
                        Button("New Message to \(message.senderDisplay)") { store.newMessage(to: MessageBuilder.format(message.sender)) }
                    }
                    recipients
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 6) {
                    Text(RelativeDate.detailed(message.date)).font(.system(size: 12)).foregroundStyle(Theme.text3)
                    if let alias = store.receivingAlias(for: message) {
                        TagChip(text: alias, symbol: "at", color: Theme.accentText).help("Received at this alias — replies come from it")
                    }
                }
            }

            InsightCard(message: message)

            if case .loaded(let parsed) = store.bodyState, !parsed.attachments.isEmpty {
                AttachmentStrip(attachments: parsed.attachments)
            }
        }
        .padding(.horizontal, 26)
        .padding(.top, 22)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var recipients: some View {
        let me = store.myAddresses
        func name(_ a: MailAddress) -> String { me.contains(a.email.lowercased()) ? "me" : (a.name.isEmpty ? a.email : a.name) }
        var parts: [String] = []
        if !message.to.isEmpty { parts.append("to " + message.to.map(name).joined(separator: ", ")) }
        if !message.cc.isEmpty { parts.append("cc " + message.cc.map(name).joined(separator: ", ")) }
        return Text(parts.joined(separator: "  ·  "))
            .font(.system(size: 12.5))
            .foregroundStyle(Theme.text3)
            .lineLimit(2)
            .help((message.to + message.cc).map(MessageBuilder.format).joined(separator: ", "))
    }

    @ViewBuilder
    private var content: some View {
        switch store.bodyState {
        case .loaded(let parsed):
            let blocked = store.blockRemoteContent && !allowRemoteFor.contains(message.id)
            let isHTML = parsed.html?.isEmpty == false
            VStack(spacing: 0) {
                if blocked && MessageHTML.cachedHasRemote(parsed, key: message.id) {
                    HStack(spacing: 8) {
                        Image(systemName: "eye.slash")
                        Text("Remote images blocked for privacy.")
                        Spacer()
                        Button("Load images") { allowRemoteFor.insert(message.id) }.buttonStyle(.link)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text2)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .panel(radius: 9, fill: Theme.sunken)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
                }
                MessageWebView(
                    document: MessageHTML.cachedDocument(for: parsed, key: message.id),
                    key: message.id,
                    inline: parsed.inline,
                    blockRemote: blocked,
                    onMailto: { store.compose(mailto: $0) }
                )
                .clipShape(RoundedRectangle(cornerRadius: isHTML ? 14 : 0, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(isHTML ? Theme.hairline : .clear))
                .padding(.horizontal, isHTML ? 18 : 0)
                .padding(.bottom, isHTML ? 18 : 0)
            }
        case .loading:
            LoadingBody()
        case .failed(let reason):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.icloud").font(.system(size: 26)).foregroundStyle(Theme.text3)
                Text("Couldn’t load this message").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                Text(reason).font(.system(size: 12)).foregroundStyle(Theme.text3).multilineTextAlignment(.center)
                PillButton(title: "Try again", symbol: "arrow.clockwise") { store.retryOpen() }
            }
            .padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case nil:
            Color.clear
        }
    }
}

/// Claude's read on the conversation: where it stands, a dated timeline, and the thread itself.
struct InsightCard: View {
    @Environment(MailStore.self) private var store
    let message: MessageSummary
    @State private var showThread = true

    var body: some View {
        let insight = store.insights[message.id]
        let deep = store.deepSummaries[message.id]
        let busy = store.summarizing.contains(message.id)
        let convo = store.conversation(for: message.id)
        if insight != nil || deep != nil || store.aiReady || (convo?.count ?? 0) > 1 {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    SparkleIcon(size: 11)
                    Text(statusLine(insight, convo)).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text2)
                    if let insight, insight.priority >= 3 {
                        Text("Urgent").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.urgent)
                    }
                    Spacer()
                    if deep == nil && store.aiReady {
                        Button(busy ? "Reading…" : "Summarize") { store.summarize(message) }
                            .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text2).disabled(busy)
                    }
                    if let insight, !insight.done, insight.priority >= 1 {
                        Button { store.setDone(message.id) } label: { Label("Done", systemImage: "checkmark") }
                            .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text2)
                    }
                }
                if busy { ThinkingBar() }
                if let deep {
                    Text(deep.tldr).font(.system(size: 13.5)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                    ForEach(deep.keyPoints, id: \.self) { p in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("–").foregroundStyle(Theme.text3)
                            Text(p).font(.system(size: 12.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    ForEach(deep.actionItems, id: \.self) { a in
                        Label(a, systemImage: "arrow.turn.down.right").font(.system(size: 12.5)).foregroundStyle(Theme.text)
                    }
                } else if let insight {
                    Text(insight.summary).font(.system(size: 13.5)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                    if !insight.action.isEmpty {
                        Label(insight.action, systemImage: "arrow.turn.down.right").font(.system(size: 12.5)).foregroundStyle(Theme.text2)
                    }
                } else if !busy {
                    Text("Not analyzed yet.").font(.system(size: 12.5)).foregroundStyle(Theme.text3)
                }
                if let insight, !insight.timeline.isEmpty { TimelineStrip(events: insight.timeline) }
                if let convo, convo.count > 1 { thread(convo) }
            }
            .padding(14)
            .panel(radius: 10, fill: Theme.sunken)
        }
    }

    private func statusLine(_ i: Insight?, _ c: Conversation?) -> String {
        var parts: [String] = []
        if let c, c.lastFromMe {
            let days = Calendar.current.dateComponents([.day], from: c.latest.date, to: Date()).day ?? 0
            parts.append("You replied \(days == 0 ? "today" : "\(days)d ago") · waiting on \(c.counterpart.display)")
        } else if let i {
            parts.append(i.statusLabel)
            if let c, c.myLastReply == nil, i.status == "needs_reply" { parts.append("no reply from you yet") }
        } else if let c, c.myLastReply != nil {
            parts.append("You’re part of this conversation")
        }
        if let i, let due = i.dueDay { parts.append(ConversationRow.dueText(due)) }
        return parts.isEmpty ? "Claude" : parts.joined(separator: " · ")
    }

    private func thread(_ c: Conversation) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.snappy(duration: 0.2)) { showThread.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: showThread ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                    Text("Conversation · \(c.count) messages").font(.system(size: 11.5, weight: .medium))
                }
                .foregroundStyle(Theme.text3)
            }
            .buttonStyle(.plain)
            .padding(.bottom, showThread ? 8 : 0)
            if showThread {
                ForEach(c.messages.suffix(8)) { m in
                    let current = m.id == message.id
                    HStack(spacing: 10) {
                        Circle().fill(c.isFromMe(m) ? Theme.text3 : Theme.text).frame(width: 5, height: 5)
                        Text(c.isFromMe(m) ? "You" : m.senderDisplay)
                            .font(.system(size: 12, weight: current ? .semibold : .regular))
                            .foregroundStyle(Theme.text)
                            .frame(width: 110, alignment: .leading)
                            .lineLimit(1)
                        Text(m.snippet.isEmpty ? m.displaySubject : m.snippet)
                            .font(.system(size: 12)).foregroundStyle(Theme.text3).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(RelativeDate.short(m.date)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.text3)
                    }
                    .padding(.vertical, 5)
                    .padding(.horizontal, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(current ? Theme.hover : .clear))
                    .contentShape(Rectangle())
                    .onTapGesture { if !current { store.selection = [m.id] } }
                }
            }
        }
        .padding(.top, 2)
    }
}

/// A compact horizontal timeline of milestones and upcoming dates.
struct TimelineStrip: View {
    let events: [TimelineEvent]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(events.enumerated()), id: \.offset) { idx, e in
                HStack(alignment: .top, spacing: 10) {
                    VStack(spacing: 0) {
                        Circle()
                            .strokeBorder(e.upcoming ? Theme.text : Theme.text3, lineWidth: 1.2)
                            .background(Circle().fill(e.upcoming ? Theme.sunken : Theme.text3))
                            .frame(width: 7, height: 7)
                            .padding(.top, 4)
                        if idx < events.count - 1 {
                            Rectangle().fill(Theme.hairline).frame(width: 1).frame(maxHeight: .infinity)
                        }
                    }
                    .frame(width: 8)
                    Text(e.day.map { $0.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) } ?? e.date)
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(e.upcoming ? Theme.text : Theme.text3)
                        .frame(width: 84, alignment: .leading)
                    Text(e.text)
                        .font(.system(size: 12.5))
                        .foregroundStyle(e.upcoming ? Theme.text : Theme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, idx < events.count - 1 ? 8 : 0)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

private struct LoadingBody: View {
    @State private var visible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(0..<6) { i in
                RoundedRectangle(cornerRadius: 4).fill(Theme.hover)
                    .frame(height: 11)
                    .frame(maxWidth: i == 5 ? 180 : (i % 2 == 0 ? .infinity : 420))
            }
            Spacer()
        }
        .padding(.horizontal, 26)
        .padding(.top, 10)
        .opacity(visible ? 1 : 0)
        .task {
            try? await Task.sleep(for: .milliseconds(180))
            withAnimation(.easeIn(duration: 0.2)) { visible = true }
        }
    }
}

private struct AttachmentStrip: View {
    @Environment(MailStore.self) private var store
    let attachments: [Attachment]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { a in
                    Button { store.open(a) } label: { AttachmentChip(attachment: a) }
                        .buttonStyle(.plain)
                        .help("Open \(a.filename)")
                        .contextMenu {
                            Button("Open") { store.open(a) }
                            Button("Save As…") { store.save(a) }
                        }
                }
            }
        }
    }
}

private struct AttachmentChip: View {
    let attachment: Attachment
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            thumbnail.frame(width: 32, height: 32).clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.filename).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                Text(attachment.sizeDescription).font(.system(size: 10.5)).foregroundStyle(Theme.text3)
            }
            .frame(maxWidth: 170, alignment: .leading)
        }
        .padding(.leading, 6)
        .padding(.trailing, 12)
        .padding(.vertical, 6)
        .panel(radius: 11, fill: hovering ? Theme.hover : Theme.raised)
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var thumbnail: some View {
        if attachment.mimeType.hasPrefix("image/"), attachment.data.count < 8_000_000, let image = NSImage(data: attachment.data) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Theme.accentSoft
                Image(systemName: attachment.symbol).foregroundStyle(Theme.accentText).font(.system(size: 13))
            }
        }
    }
}
