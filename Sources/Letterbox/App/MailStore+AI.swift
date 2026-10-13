import Foundation
import SwiftUI

enum AIStatus: Equatable {
    case unknown
    case off
    case missing
    case ready
    case working(String)
    case failed(String)

    var isWorking: Bool { if case .working = self { return true }; return false }
}

extension Briefing {
    static func load() -> Briefing? {
        guard let d = UserDefaults.standard.data(forKey: "briefing") else { return nil }
        return try? JSONDecoder().decode(Briefing.self, from: d)
    }
    func save() { UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: "briefing") }
    static func clear() { UserDefaults.standard.removeObject(forKey: "briefing") }
}

struct ConversationItem: Identifiable {
    let conversation: Conversation
    let insight: Insight
    var id: String { conversation.id }
    var message: MessageSummary { conversation.latestIncoming ?? conversation.latest }
}

struct AgendaEntry: Identifiable {
    let id: String
    let day: Date
    let text: String
    let item: ConversationItem
}

/// Dashboard-ready view of open conversations.
struct DashboardModel {
    var needsReply: [ConversationItem] = []
    var todo: [ConversationItem] = []
    var waiting: [ConversationItem] = []
    var agenda: [AgendaEntry] = []
    var low: [ConversationItem] = []
    var unread = 0
    var pending = 0

    var dueThisWeek: Int {
        let limit = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
        return agenda.filter { $0.day <= limit }.count
    }
}

extension MailStore {
    // MARK: Setup

    func setupAI() {
        guard aiEnabled else { claude = nil; aiStatus = .off; return }
        let preferred = claudePath
        let model = aiModel
        Task {
            let url = await Task.detached { ClaudeCLI.locate(preferred: preferred) }.value
            if let url {
                claude = ClaudeCLI(executable: url, model: model)
                if claudePath.isEmpty { claudePath = url.path }
                aiStatus = .ready
                if account != nil { scheduleTriage() }
            } else {
                claude = nil
                aiStatus = .missing
            }
        }
    }

    var aiReady: Bool { claude != nil && aiEnabled }

    // MARK: Conversations

    private var threadFolders: [String] {
        folders.filter { [.inbox, .sent, .archive, .custom].contains($0.role) }.map(\.path)
    }

    func rebuildConversations() {
        let pool = repo.threadPool(folders: threadFolders, since: Date().addingTimeInterval(-75 * 86400))
        let convs = ThreadBuilder.build(pool, me: myAddresses, sentFolder: folder(.sent)?.path)
        var threadOf: [String: String] = [:]
        var byID: [String: Conversation] = [:]
        var known: [String: MessageSummary] = [:]
        for c in convs {
            byID[c.id] = c
            for m in c.messages {
                threadOf[m.id] = c.id
                known[m.id] = m
            }
        }
        self.threadOf = threadOf
        conversationByID = byID
        knownMessages = known
        conversations = convs
        reindexInsights()
    }

    func reindexInsights() {
        var map: [String: Insight] = [:]
        for c in conversations {
            guard var i = threadInsights[c.id] else { continue }
            // The server state is the truth about who wrote last.
            if c.lastFromMe && i.status == "needs_reply" { i.status = "waiting" }
            if c.lastFromMe { i.needsReply = false }
            for m in c.messages { map[m.id] = i }
        }
        insights = map
    }

    func conversation(for messageID: String) -> Conversation? {
        threadOf[messageID].flatMap { conversationByID[$0] }
    }

    // MARK: Dashboard

    var dashboard: DashboardModel {
        var d = DashboardModel()
        let cutoff = Date().addingTimeInterval(-30 * 86400)
        let inboxPath = inbox?.path
        for c in conversations where c.latest.date >= cutoff && c.hasIncoming {
            if c.messages.contains(where: { $0.folder == inboxPath && !$0.seen }) { d.unread += 1 }
            guard let raw = threadInsights[c.id] else {
                if c.messages.contains(where: { $0.folder == inboxPath }) { d.pending += 1 }
                continue
            }
            var i = raw
            if c.lastFromMe && i.status == "needs_reply" { i.status = "waiting" }
            guard !i.done else { continue }
            let item = ConversationItem(conversation: c, insight: i)
            switch i.status {
            case "needs_reply": d.needsReply.append(item)
            case "action": d.todo.append(item)
            case "waiting": d.waiting.append(item)
            default: if i.priority == 0 { d.low.append(item) }
            }
            if i.status != "resolved" && i.priority >= 1 {
                let today = Calendar.current.startOfDay(for: Date())
                var dates = Set<String>()
                for (n, e) in i.timeline.enumerated() where e.upcoming {
                    if let day = e.day, day >= today, dates.insert(e.date).inserted {
                        d.agenda.append(AgendaEntry(id: c.id + "e\(n)", day: day, text: e.text, item: item))
                    }
                }
                if let day = i.dueDay, !dates.contains(i.dueDate), day >= today.addingTimeInterval(-7 * 86400) {
                    d.agenda.append(AgendaEntry(id: c.id + "due", day: day, text: i.action.isEmpty ? i.reason.isEmpty ? i.summary : i.reason : i.action, item: item))
                }
            }
        }
        let rank: (ConversationItem, ConversationItem) -> Bool = {
            $0.insight.priority != $1.insight.priority ? $0.insight.priority > $1.insight.priority : $0.conversation.latest.date > $1.conversation.latest.date
        }
        d.needsReply.sort(by: rank)
        d.todo.sort(by: rank)
        d.waiting.sort { ($0.conversation.myLastReply ?? .distantPast) < ($1.conversation.myLastReply ?? .distantPast) }
        d.agenda.sort { $0.day < $1.day }
        return d
    }

    func setDone(_ messageID: String, _ done: Bool = true) {
        guard let thread = threadOf[messageID], var i = threadInsights[thread] else { return }
        i.done = done
        withAnimation(.snappy) { threadInsights[thread] = i }
        repo.setThreadDone(done, thread: thread)
        reindexInsights()
        if done { showToast("Marked as done", symbol: "checkmark") }
    }

    func archiveLowPriority() {
        let ids = dashboard.low.flatMap { $0.conversation.messages.filter { $0.folder == inbox?.path }.map(\.id) }
        guard !ids.isEmpty else { return }
        archive(ids)
    }

    // MARK: Triage

    func scheduleTriage(force: Bool = false) {
        guard aiReady, triageTask == nil else { return }
        triageTask = Task { [weak self] in
            await self?.runTriage(force: force)
            self?.triageTask = nil
        }
    }

    private func runTriage(force: Bool) async {
        guard let claude, let account else { return }
        if conversations.isEmpty { rebuildConversations() }
        let inboxPath = inbox?.path
        let cutoff = Date().addingTimeInterval(-21 * 86400)
        let candidates = conversations.filter { c in
            c.latest.date >= cutoff && c.hasIncoming && c.messages.contains { $0.folder == inboxPath }
                && (force ? true : threadInsights[c.id]?.latestID != c.latest.id)
        }
        .prefix(force ? 80 : 60)
        let stale = briefing.map { Date().timeIntervalSince($0.generated) > 3 * 3600 } ?? true
        guard !candidates.isEmpty || stale else { return }

        let user = "\(account.displayName) <\(account.email)>"
        let repo = repo
        let list = Array(candidates)
        let batches = stride(from: 0, to: list.count, by: 8).map { Array(list[$0..<min($0 + 8, list.count)]) }
        var remaining = list.count
        for batch in batches {
            aiStatus = .working("Reading \(remaining) conversation\(remaining == 1 ? "" : "s")…")
            let blocks: [String] = await Task.detached {
                batch.enumerated().map { idx, c in
                    var bodies: [String: String] = [:]
                    for m in c.messages.suffix(6) {
                        if let raw = repo.body(folder: m.folder, uid: m.uid) {
                            bodies[m.id] = ThreadBuilder.newContent(MessageParser.parse(raw).quotableText)
                        }
                    }
                    return Assistant.threadBlock(id: "c\(idx + 1)", conversation: c, bodies: bodies)
                }
            }.value
            do {
                let r = try await claude.structured(Assistant.ThreadResponse.self, prompt: Assistant.threadPrompt(blocks),
                                                    system: Assistant.threadSystem(user: user), schema: Assistant.threadSchema)
                for item in r.items {
                    guard let n = Int(item.id.dropFirst()), batch.indices.contains(n - 1) else { continue }
                    let c = batch[n - 1]
                    var status = item.status
                    if c.lastFromMe && status == "needs_reply" { status = "waiting" }
                    let insight = Insight(
                        priority: max(0, min(3, item.priority)), category: item.category, summary: item.summary,
                        reason: item.reason ?? "", action: item.action ?? "", due: "", needsReply: status == "needs_reply",
                        done: threadInsights[c.id]?.latestID == c.latest.id ? (threadInsights[c.id]?.done ?? false) : false,
                        status: status, dueDate: item.due_date ?? "",
                        timeline: (item.timeline ?? []).map { TimelineEvent(date: $0.date, text: $0.text, upcoming: $0.upcoming) },
                        latestID: c.latest.id)
                    repo.saveThreadInsight(insight, thread: c.id)
                    withAnimation(.snappy) { threadInsights[c.id] = insight }
                }
                reindexInsights()
                remaining -= batch.count
            } catch {
                aiStatus = .failed(error.localizedDescription)
                return
            }
        }
        await refreshBriefing()
    }

    func refreshBriefing() async {
        guard let claude, let account else { return }
        let d = dashboard
        var lines: [String] = []
        let df = DateFormatter()
        df.dateFormat = "EEE d MMM"
        for i in d.needsReply.prefix(8) { lines.append("- NEEDS REPLY [\(Theme.priorityLabel(i.insight.priority))] \(i.conversation.counterpart.display): \(i.insight.summary)") }
        for i in d.todo.prefix(8) { lines.append("- TO DO [\(Theme.priorityLabel(i.insight.priority))] \(i.insight.action.isEmpty ? i.insight.summary : i.insight.action) (\(i.conversation.counterpart.display))") }
        for i in d.waiting.prefix(6) {
            let since = i.conversation.myLastReply.map { " since \(df.string(from: $0))" } ?? ""
            lines.append("- WAITING on \(i.conversation.counterpart.display)\(since): \(i.insight.summary)")
        }
        for a in d.agenda.prefix(8) { lines.append("- DATE \(df.string(from: a.day)): \(a.text)") }
        guard !lines.isEmpty else {
            briefing = Briefing(headline: "Nothing needs you right now.", highlights: [], generated: Date())
            briefing?.save()
            aiStatus = .ready
            return
        }
        aiStatus = .working("Writing your briefing…")
        do {
            let r = try await claude.structured(Assistant.BriefingResponse.self, prompt: Assistant.briefingPrompt(lines, unread: d.unread),
                                                system: Assistant.briefingSystem(user: account.displayName.isEmpty ? account.email : account.displayName),
                                                schema: Assistant.briefingSchema)
            withAnimation(.smooth) { briefing = Briefing(headline: r.headline, highlights: r.highlights, generated: Date()) }
            briefing?.save()
            aiStatus = .ready
        } catch {
            aiStatus = .failed(error.localizedDescription)
        }
    }

    // MARK: Summaries

    func summarize(_ m: MessageSummary) {
        guard let claude, let account, !summarizing.contains(m.id) else { return }
        summarizing.insert(m.id)
        let body: String
        if let c = conversation(for: m.id), c.count > 1 {
            body = c.messages.suffix(6).map { msg in
                let text = bodyCache[msg.id].map { ThreadBuilder.newContent($0.quotableText) } ?? msg.snippet
                return "[\(RelativeDate.detailed(msg.date))] \(c.isFromMe(msg) ? "YOU" : msg.senderDisplay):\n\(text)"
            }.joined(separator: "\n\n")
        } else {
            body = bodyCache[m.id]?.quotableText ?? m.snippet
        }
        Task {
            defer { summarizing.remove(m.id) }
            do {
                let s = try await claude.structured(DeepSummary.self,
                                                    prompt: Assistant.summaryPrompt(from: MessageBuilder.format(m.sender), subject: m.displaySubject, body: body),
                                                    system: Assistant.summarySystem(user: account.displayName), schema: Assistant.summarySchema)
                withAnimation(.smooth) { deepSummaries[m.id] = s }
            } catch {
                showToast(error.localizedDescription, symbol: "exclamationmark.triangle")
            }
        }
    }

    // MARK: Drafting

    func draftWithClaude(_ m: MessageSummary, tone: ReplyTone? = nil, instruction: String = "") {
        let target = conversation(for: m.id)?.latestIncoming ?? m
        if bodyCache[target.id] == nil, let raw = repo.body(folder: target.folder, uid: target.uid) {
            bodyCache[target.id] = MessageParser.parse(raw)
        }
        guard let d = reply(all: false, to: target) else { return }
        if let c = conversation(for: target.id), c.count > 1 {
            d.context = c.messages.suffix(6).map { msg in
                let text = bodyCache[msg.id].map { ThreadBuilder.newContent($0.quotableText) }
                    ?? repo.body(folder: msg.folder, uid: msg.uid).map { ThreadBuilder.newContent(MessageParser.parse($0).quotableText) }
                    ?? msg.snippet
                return "[\(RelativeDate.detailed(msg.date))] \(c.isFromMe(msg) ? "ME" : msg.senderDisplay):\n\(text)"
            }.joined(separator: "\n\n")
        }
        d.aiTone = tone
        d.aiInstruction = instruction
        d.autoGenerate = aiReady
    }

    func generate(_ d: ComposeDraft) {
        guard let claude, let account else { d.aiError = "Claude isn’t available. Check Settings → Claude."; return }
        d.aiTask?.cancel()
        d.aiError = nil
        d.aiBusy = true
        let fromName = addresses.first { $0.email == d.fromEmail.lowercased() }?.name
        let name = (fromName?.isEmpty == false ? fromName! : account.displayName)
        let system: String
        let prompt: String
        if d.context.isEmpty {
            system = Assistant.composeSystem(name: name, email: d.fromEmail)
            prompt = "Write an email. Subject: \(d.subject.isEmpty ? "(none yet)" : d.subject). To: \(d.to).\nWhat it should say: \(d.aiInstruction.isEmpty ? "Use the subject as the brief." : d.aiInstruction)\(d.aiTone.map { "\nTone: \($0.rawValue)" } ?? "")"
        } else {
            system = Assistant.replySystem(name: name, email: d.fromEmail)
            prompt = Assistant.replyPrompt(from: d.contextFrom, subject: d.contextSubject, date: d.contextDate, body: d.context,
                                           instruction: d.aiInstruction, tone: d.aiTone)
        }
        let signatureBlock = signature.isEmpty ? "" : "\n\n-- \n\(signature)"
        d.aiTask = Task {
            var text = ""
            do {
                for try await chunk in claude.stream(prompt: prompt, system: system) {
                    text += chunk
                    d.body = text.trimmingCharacters(in: .newlines) + signatureBlock
                    d.bodyRevision += 1
                }
            } catch {
                if !Task.isCancelled { d.aiError = error.localizedDescription }
            }
            d.aiBusy = false
        }
    }

    func improve(_ d: ComposeDraft, kind: ImproveKind) {
        guard let claude else { d.aiError = "Claude isn’t available. Check Settings → Claude."; return }
        var draft = d.body
        var sig = ""
        if let r = draft.range(of: "\n-- \n", options: .backwards) {
            sig = String(draft[r.lowerBound...])
            draft = String(draft[..<r.lowerBound])
        }
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { d.aiError = "Write something first, or ask Claude to draft it."; return }
        d.aiTask?.cancel()
        d.aiError = nil
        d.aiBusy = true
        let prompt = Assistant.improvePrompt(draft, kind: kind, context: d.context)
        d.aiTask = Task {
            var text = ""
            do {
                for try await chunk in claude.stream(prompt: prompt, system: Assistant.improveSystem()) {
                    text += chunk
                    d.body = text.trimmingCharacters(in: .newlines) + sig
                    d.bodyRevision += 1
                }
            } catch {
                if !Task.isCancelled { d.aiError = error.localizedDescription }
            }
            d.aiBusy = false
        }
    }

    // MARK: Ask

    /// Opens the assistant with a question already asked.
    func startAsk(_ question: String) {
        pendingAsk = question
        showPalette = true
    }

    func ask(_ question: String) -> AsyncThrowingStream<String, Error> {
        guard let claude, let account else {
            return AsyncThrowingStream { $0.finish(throwing: ClaudeError(message: "Claude isn’t available. Check Settings → Claude.")) }
        }
        let df = DateFormatter()
        df.dateFormat = "EEE d MMM"
        let lines = conversations.prefix(120).map { c -> String in
            var s = "- \"\(c.subject)\" with \(c.counterpart.display) · \(c.count) msg · last \(df.string(from: c.latest.date)) by \(c.lastFromMe ? "ME" : c.latest.senderDisplay)"
            if let i = threadInsights[c.id] {
                s += " · status \(i.status) · \(i.summary)"
                if !i.action.isEmpty { s += " · todo: \(i.action)" }
                if !i.dueDate.isEmpty { s += " · due \(i.dueDate)" }
            } else if !c.latest.snippet.isEmpty {
                s += " · \(c.latest.snippet.prefix(140))"
            }
            return s
        }
        return claude.stream(prompt: Assistant.askPrompt(question: question, context: Array(lines)),
                             system: Assistant.askSystem(user: account.displayName.isEmpty ? account.email : account.displayName))
    }
}
