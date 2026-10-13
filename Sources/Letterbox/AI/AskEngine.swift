import Foundation
import Observation

/// What Claude proposes to do to a set of conversations. Nothing runs until the user confirms.
struct ProposedAction: Equatable {
    enum Kind: String { case trash, archive, markRead = "mark_read", flag }
    var kind: Kind
    var summary: String
    var conversations: [String]
    var selected: Set<String>
    var executed = false

    var verb: String {
        switch kind {
        case .trash: return "Move to Trash"
        case .archive: return "Archive"
        case .markRead: return "Mark as read"
        case .flag: return "Flag"
        }
    }
}

struct AskTurn: Identifiable {
    let id = UUID()
    let question: String
    var answer = ""
    var refs: [String] = []          // conversation ids
    var action: ProposedAction?
    var error: String?
    var stage = "Finding relevant conversations…"
    var done = false
}

@Observable @MainActor
final class AskSession {
    var turns: [AskTurn] = []
    var busy = false
    @ObservationIgnored var task: Task<Void, Never>?
}

extension Assistant {
    struct SelectResponse: Decodable {
        let relevant: [String]
    }

    static let selectSchema = """
    {"type":"object","properties":{"relevant":{"type":"array","items":{"type":"string"},"maxItems":12}},"required":["relevant"]}
    """

    struct AnswerResponse: Decodable {
        struct Action: Decodable {
            let type: String
            let conversations: [String]
            let summary: String
        }
        let answer: String
        let refs: [String]
        let action: Action
    }

    static let answerSchema = """
    {"type":"object","properties":{
    "answer":{"type":"string"},
    "refs":{"type":"array","items":{"type":"string"},"maxItems":10},
    "action":{"type":"object","properties":{
        "type":{"type":"string","enum":["none","trash","archive","mark_read","flag"]},
        "conversations":{"type":"array","items":{"type":"string"}},
        "summary":{"type":"string"}},"required":["type","conversations","summary"]}},
    "required":["answer","refs","action"]}
    """

    static func selectSystem(user: String) -> String {
        """
        You help \(user) find things in their email. Given an index of conversations and a request, return the ids \
        of the conversations whose full text would help answer it (at most 12, most relevant first). \
        Return an empty list if the index alone is enough (e.g. counting, listing, or cleaning up by sender/category). \(safety)
        """
    }

    static func answerSystem(user: String, today: String) -> String {
        """
        You are the assistant inside \(user)'s email client. Today is \(today).
        You get an index of recent conversations (one per line, starting with an id like c12) and the full text of some of them.
        answer: reply directly and specifically in plain text (short paragraphs or "• " bullets, no markdown headings). \
        Mention senders, dates, amounts and other details from the emails. If something isn't in the data, say so. \
        Never show ids like "c12" to the user — refer to senders and subjects instead.
        refs: ids of the conversations your answer relies on, most important first.
        action: only when the user explicitly asks to clean up, delete, trash, archive, mark as read or flag mail — otherwise type "none" with an empty list. \
        For clean-ups, pick conversations from the whole index that clearly match the request (e.g. newsletters, promotions, \
        automated notifications, old FYIs). Never include conversations that need the user's reply, have open action items, \
        involve money/security/legal matters, or are from real people unless the user asked for that. Prefer "archive" when the user \
        says "clean up" without saying delete. Nothing happens until the user confirms, so in the answer describe it as a proposal \
        ("I can archive these 12…"), never as already done. summary: one sentence describing what will happen and why.
        \(safety)
        """
    }
}

extension MailStore {
    /// Compact, id-keyed index of recent conversations for the assistant.
    func assistantIndex(limit: Int = 220) -> (lines: [String], ids: [String: Conversation]) {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        var ids: [String: Conversation] = [:]
        var lines: [String] = []
        let trash = folder(.trash)?.path, junk = folder(.junk)?.path
        for (n, c) in conversations.prefix(limit).enumerated() {
            let key = "c\(n + 1)"
            ids[key] = c
            let folders = Set(c.messages.map(\.folder)).filter { $0 != trash && $0 != junk }
                .compactMap { p in self.folders.first { $0.path == p }?.displayName }.sorted().joined(separator: "+")
            var s = "\(key) | \(df.string(from: c.latest.date)) | \(c.counterpart.display) <\(c.counterpart.email)> | \"\(c.subject)\" | \(c.count) msg | last by \(c.lastFromMe ? "ME" : "THEM")"
            if c.unread { s += " | unread" }
            if !folders.isEmpty { s += " | \(folders)" }
            if let i = threadInsights[c.id] {
                s += " | \(i.status) p\(i.priority) \(i.category) | \(i.summary)"
                if !i.action.isEmpty { s += " | todo: \(i.action)" }
                if !i.dueDate.isEmpty { s += " | due \(i.dueDate)" }
            } else if !c.latest.snippet.isEmpty {
                s += " | \(c.latest.snippet.prefix(150))"
            }
            lines.append(s)
        }
        return (lines, ids)
    }

    private func fullText(_ c: Conversation) -> String {
        c.messages.suffix(8).map { m in
            var text = bodyCache[m.id].map { ThreadBuilder.newContent($0.quotableText) }
            if text == nil, let raw = repo.body(folder: m.folder, uid: m.uid) {
                text = ThreadBuilder.newContent(MessageParser.parse(raw).quotableText)
            }
            let who = c.isFromMe(m) ? "ME" : MessageBuilder.format(m.sender)
            return "[\(RelativeDate.detailed(m.date))] \(who) — \(m.displaySubject)\n\(String((text ?? m.snippet).prefix(2500)))"
        }.joined(separator: "\n\n")
    }

    func ask(_ question: String, in session: AskSession) {
        guard let claude, let account else {
            var t = AskTurn(question: question)
            t.error = "Claude isn’t available. Check Settings → Claude."
            t.done = true
            session.turns.append(t)
            return
        }
        session.task?.cancel()
        session.turns.append(AskTurn(question: question))
        let index = session.turns.count - 1
        session.busy = true
        let user = account.displayName.isEmpty ? account.email : "\(account.displayName) <\(account.email)>"
        let (lines, ids) = assistantIndex()
        let history = session.turns.dropLast().suffix(4).map { "User: \($0.question)\nAssistant: \($0.answer)" }.joined(separator: "\n\n")
        let today = Date().formatted(.dateTime.weekday(.wide).day().month(.wide).year())

        session.task = Task {
            defer { session.busy = false; session.turns[index].done = true }
            do {
                let indexText = lines.joined(separator: "\n")
                let selection = try await claude.structured(
                    Assistant.SelectResponse.self,
                    prompt: "Conversation index:\n\(indexText)\n\n\(history.isEmpty ? "" : "Earlier in this chat:\n\(history)\n\n")Request: \(question)",
                    system: Assistant.selectSystem(user: user), schema: Assistant.selectSchema)
                guard !Task.isCancelled else { return }
                let picked = selection.relevant.compactMap { id in ids[id].map { (id, $0) } }
                session.turns[index].stage = picked.isEmpty ? "Thinking…" : "Reading \(picked.count) conversation\(picked.count == 1 ? "" : "s")…"

                var details = ""
                for (id, c) in picked {
                    details += "<conversation id=\"\(id)\" subject=\"\(c.subject)\">\n\(fullText(c))\n</conversation>\n\n"
                }
                let prompt = """
                Conversation index:
                \(indexText)

                \(details.isEmpty ? "" : "Full text of relevant conversations:\n\(details)")
                \(history.isEmpty ? "" : "Earlier in this chat:\n\(history)\n")
                Request: \(question)
                """
                let r = try await claude.structured(Assistant.AnswerResponse.self, prompt: prompt,
                                                    system: Assistant.answerSystem(user: user, today: today), schema: Assistant.answerSchema)
                guard !Task.isCancelled else { return }
                session.turns[index].answer = r.answer
                session.turns[index].refs = r.refs.compactMap { ids[$0]?.id }
                if let kind = ProposedAction.Kind(rawValue: r.action.type) {
                    let convs = r.action.conversations.compactMap { ids[$0]?.id }
                    if !convs.isEmpty {
                        session.turns[index].action = ProposedAction(kind: kind, summary: r.action.summary, conversations: convs, selected: Set(convs))
                    }
                }
            } catch {
                if !Task.isCancelled { session.turns[index].error = error.localizedDescription }
            }
        }
    }

    /// Runs a confirmed proposal on the selected conversations.
    func perform(_ action: ProposedAction) -> Int {
        let sent = folder(.sent)?.path, trash = folder(.trash)?.path
        let messages = action.conversations.filter { action.selected.contains($0) }
            .compactMap { conversationByID[$0] }
            .flatMap(\.messages)
            .filter { $0.folder != sent && $0.folder != trash }
        let ids = messages.map(\.id)
        guard !ids.isEmpty else { return 0 }
        switch action.kind {
        case .trash:
            if let trash { move(ids, to: trash, label: "Moved \(ids.count) messages to Trash", symbol: "trash") }
        case .archive:
            archive(ids)
        case .markRead:
            applyRead(ids)
        case .flag:
            toggleFlag(ids)
        }
        rebuildConversations()
        return ids.count
    }
}
