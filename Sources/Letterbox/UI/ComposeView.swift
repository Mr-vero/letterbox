import SwiftUI
import UniformTypeIdentifiers

struct ComposeView: View {
    @Environment(MailStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Bindable var draft: ComposeDraft
    @FocusState private var focus: Field?

    enum Field: Hashable { case to, cc, bcc, subject }

    var body: some View {
        VStack(spacing: 0) {
            composeHeader
            Rectangle().fill(Theme.hairline).frame(height: 1)
            fromRow
            divider
            FieldRow(label: "To") {
                RecipientField(text: $draft.to, contacts: store.contacts)
                    .focused($focus, equals: .to)
                Button(draft.showCcBcc ? "Hide Cc" : "Cc/Bcc") {
                    withAnimation(.snappy(duration: 0.2)) { draft.showCcBcc.toggle() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
            }
            .zIndex(3)
            if draft.showCcBcc {
                divider
                FieldRow(label: "Cc") {
                    RecipientField(text: $draft.cc, contacts: store.contacts).focused($focus, equals: .cc)
                }
                .zIndex(2)
                divider
                FieldRow(label: "Bcc") {
                    RecipientField(text: $draft.bcc, contacts: store.contacts).focused($focus, equals: .bcc)
                }
                .zIndex(1)
            }
            divider
            FieldRow(label: "Subject") {
                TextField("", text: $draft.subject)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .focused($focus, equals: .subject)
            }
            divider
            AIComposeBar(draft: draft)
            BodyEditor(text: $draft.body, editable: !draft.aiBusy, focusOnAppear: draft.isReply || (!draft.to.isEmpty && !draft.subject.isEmpty))
            if !draft.quote.isEmpty { quoteSection }
            if !draft.attachments.isEmpty { attachmentTray }
            if let error = draft.error { errorBar(error) }
        }
        .background(Theme.panel)
        .navigationTitle(draft.subject.isEmpty ? "New Message" : draft.subject)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in attach(url) } }
                }
            }
            return true
        }
        .onAppear {
            if draft.autoGenerate {
                draft.autoGenerate = false
                store.generate(draft)
            }
            if !(draft.isReply || (!draft.to.isEmpty && !draft.subject.isEmpty)) {
                focus = draft.to.isEmpty ? .to : .subject
            }
        }
        .onDisappear {
            draft.aiTask?.cancel()
            if !draft.isSending { store.drafts[draft.id] = nil }
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 560, minHeight: 420)
    }

    private var composeHeader: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 64)
            Text(draft.subject.isEmpty ? "New message" : draft.subject)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Spacer()
            IconButton(symbol: "paperclip", help: "Attach files") { pickFiles() }
            PillButton(title: draft.isSending ? "Sending…" : "Send", symbol: "paperplane.fill", style: .primary, action: send)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(draft.isSending)
                .help("Send (⌘↩)")
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
    }

    private var divider: some View {
        Divider().padding(.leading, 16)
    }

    private var fromRow: some View {
        FieldRow(label: "From") {
            Menu {
                ForEach(store.addresses) { a in
                    Button {
                        draft.fromEmail = a.email
                    } label: {
                        if a.email == draft.fromEmail { Label(a.email, systemImage: "checkmark") } else { Text(a.email) }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(fromLabel).font(.system(size: 13))
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer()
        }
    }

    private var fromLabel: String {
        let alias = store.addresses.first { $0.email == draft.fromEmail.lowercased() }
        let name = (alias?.name.isEmpty == false ? alias!.name : store.account?.displayName) ?? ""
        return name.isEmpty ? draft.fromEmail : "\(name) <\(draft.fromEmail)>"
    }

    private var quoteSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { draft.showQuote.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "ellipsis").font(.system(size: 11, weight: .bold))
                    Text(draft.showQuote ? "Hide quoted text" : "Show quoted text")
                }
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.text3)
                .padding(.horizontal, 10)
                .frame(height: 22)
                .background(Capsule().fill(Theme.sunken))
            }
            .buttonStyle(.plain)
            if draft.showQuote {
                ScrollView {
                    Text(draft.quote)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.text3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
                .padding(12)
                .panel(radius: 10, fill: Theme.sunken)
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var attachmentTray: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(draft.attachments) { a in
                    HStack(spacing: 6) {
                        Image(systemName: "doc").foregroundStyle(.tint)
                        Text(a.filename).lineLimit(1).frame(maxWidth: 160)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(a.data.count), countStyle: .file))
                            .foregroundStyle(.secondary)
                        Button {
                            draft.attachments.removeAll { $0.id == a.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                    .font(.system(size: 11.5))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.quaternary.opacity(0.6), in: Capsule())
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }

    private func errorBar(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).lineLimit(3)
            Spacer()
            Button { draft.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.1))
    }

    private func send() {
        Task {
            if await store.send(draft) { dismiss() }
        }
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(attach)
    }

    private func attach(_ url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        draft.attachments.append(OutgoingAttachment(filename: url.lastPathComponent, mimeType: type, data: data))
    }
}

private struct FieldRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .trailing)
            content
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 38)
    }
}

/// A recipient text field with lightweight autocomplete from known contacts.
private struct RecipientField: View {
    @Binding var text: String
    let contacts: [MailAddress]
    @State private var suggestions: [MailAddress] = []
    @State private var highlighted = 0

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .onChange(of: text) { _, _ in updateSuggestions() }
            .onKeyPress(.downArrow) {
                guard !suggestions.isEmpty else { return .ignored }
                highlighted = min(highlighted + 1, suggestions.count - 1)
                return .handled
            }
            .onKeyPress(.upArrow) {
                guard !suggestions.isEmpty else { return .ignored }
                highlighted = max(highlighted - 1, 0)
                return .handled
            }
            .onKeyPress(.return) {
                guard suggestions.indices.contains(highlighted) else { return .ignored }
                accept(suggestions[highlighted])
                return .handled
            }
            .onKeyPress(.tab) {
                guard suggestions.indices.contains(highlighted) else { return .ignored }
                accept(suggestions[highlighted])
                return .handled
            }
            .onKeyPress(.escape) {
                guard !suggestions.isEmpty else { return .ignored }
                suggestions = []
                return .handled
            }
            .overlay(alignment: .topLeading) {
                if !suggestions.isEmpty {
                    suggestionList
                        .offset(y: 26)
                        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                }
            }
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element.email) { i, c in
                HStack(spacing: 8) {
                    AvatarView(name: c.name, email: c.email, size: 22)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(c.name.isEmpty ? c.email : c.name).font(.system(size: 12.5, weight: .medium))
                        if !c.name.isEmpty { Text(c.email).font(.system(size: 11)).foregroundStyle(.secondary) }
                    }
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(i == highlighted ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
                .onTapGesture { accept(c) }
            }
        }
        .padding(5)
        .frame(width: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.7), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
    }

    private var currentToken: String {
        let last = text.split(separator: ",", omittingEmptySubsequences: false).last ?? ""
        return last.trimmingCharacters(in: .whitespaces)
    }

    private func updateSuggestions() {
        let token = currentToken.lowercased()
        guard token.count >= 2, !token.contains("<") else { suggestions = []; return }
        suggestions = Array(contacts.lazy.filter {
            $0.email.lowercased().hasPrefix(token) || $0.name.lowercased().split(separator: " ").contains { $0.hasPrefix(token) }
                || $0.email.lowercased().contains(token)
        }.prefix(5))
        if suggestions.count == 1 && suggestions[0].email.lowercased() == token { suggestions = [] }
        highlighted = 0
    }

    private func accept(_ c: MailAddress) {
        var parts = text.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        if !parts.isEmpty { parts.removeLast() }
        parts = parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        parts.append(MessageBuilder.format(c))
        text = parts.joined(separator: ", ") + ", "
        suggestions = []
    }
}

/// NSTextView-backed body editor: proper undo, spell check, and the caret at the top for replies.
private struct BodyEditor: NSViewRepresentable {
    @Binding var text: String
    var editable = true
    var focusOnAppear: Bool

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let tv = scroll.documentView as! NSTextView
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.font = .systemFont(ofSize: 14)
        tv.textColor = .labelColor
        tv.textContainerInset = NSSize(width: 18, height: 14)
        tv.isAutomaticQuoteSubstitutionEnabled = true
        tv.isAutomaticDashSubstitutionEnabled = true
        tv.isContinuousSpellCheckingEnabled = true
        tv.isAutomaticLinkDetectionEnabled = true
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        tv.defaultParagraphStyle = paragraph
        tv.typingAttributes = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
        tv.string = text
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        if focusOnAppear {
            DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        tv.isEditable = editable
        guard tv.string != text else { return }
        tv.string = text
        if !editable { tv.scrollToEndOfDocument(nil) }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            text.wrappedValue = tv.string
        }
    }
}


/// Claude controls inside the composer: instruct, pick a tone, generate, or improve.
private struct AIComposeBar: View {
    @Environment(MailStore.self) private var store
    @Bindable var draft: ComposeDraft
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SparkleIcon(size: 12)
                TextField(draft.context.isEmpty ? "Tell Claude what to write…" : "Tell Claude what to say — e.g. “yes, Tuesday 3pm works”",
                          text: $draft.aiInstruction)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .onSubmit { store.generate(draft) }
                    .disabled(!store.aiReady)
                if draft.aiBusy {
                    PillButton(title: "Stop", symbol: "stop.fill", style: .secondary, compact: true) {
                        draft.aiTask?.cancel()
                        draft.aiBusy = false
                    }
                } else {
                    Menu {
                        ForEach(ImproveKind.allCases) { k in
                            Button { store.improve(draft, kind: k) } label: { Label(k.rawValue, systemImage: k.symbol) }
                        }
                    } label: {
                        Text("Improve").font(.system(size: 12, weight: .semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(!store.aiReady || draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    PillButton(title: draft.body.isEmpty || draft.body.hasPrefix("\n\n-- ") ? "Write" : "Rewrite", symbol: "sparkle", style: .ai, compact: true) {
                        store.generate(draft)
                    }
                    .disabled(!store.aiReady)
                }
            }
            if expanded {
                HStack(spacing: 6) {
                    ForEach(ReplyTone.allCases) { tone in
                        let on = draft.aiTone == tone
                        Button {
                            draft.aiTone = on ? nil : tone
                        } label: {
                            Text(tone.rawValue)
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(on ? Theme.onInk : Theme.text2)
                                .padding(.horizontal, 10)
                                .frame(height: 24)
                                .background {
                                    if on { Capsule().fill(Theme.ink) } else { Capsule().fill(Theme.raised) }
                                }
                                .overlay(Capsule().strokeBorder(on ? .clear : Theme.hairline))
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
            }
            if draft.aiBusy { ThinkingBar() }
            if let error = draft.aiError {
                Text(error).font(.system(size: 11.5)).foregroundStyle(Theme.urgent).lineLimit(3)
            }
            if !store.aiReady {
                Text("Claude isn’t connected. Set it up in Settings → Claude.").font(.system(size: 11.5)).foregroundStyle(Theme.text3)
            }
        }
        .padding(12)
        .aurora(radius: 12, animated: draft.aiBusy)
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }
}
