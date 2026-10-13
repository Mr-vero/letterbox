import AppKit
import SwiftUI

/// `Letterbox --snapshot <dir>` renders the UI offscreen with sample data and writes PNGs.
/// Development aid only; never touches the real account or cache.
@MainActor
enum Snapshot {
    static var outputDir: String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// True while rendering screenshots; scroll views are replaced by static layouts
    /// because offscreen capture can't draw them.
    static var isActive = false
    static var dashboardWidth: CGFloat = 1199

    static func run(to dir: String) {
        isActive = true
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("letterbox-demo-\(UUID().uuidString).sqlite")
        let db = Database(url: url)
        seed(db)
        var account = Account(email: "alex@example.com", displayName: "Alex Rivera")
        MailProvider.fastmail.apply(to: &account)
        let store = MailStore(demo: account, database: db)
        seedInsights(db, store: store)

        Task { @MainActor in
            let size = NSSize(width: 1440, height: 900)
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                store.selection = []
                store.sidebarSelection = .dashboard
                dashboardWidth = 1199
                await render(RootView().environment(store), size: size, appearance: appearance, to: "\(dir)/dashboard-\(name).png")

                store.selection = []
                store.sidebarSelection = .folder("INBOX")
                try? await Task.sleep(for: .milliseconds(100))
                if let m = store.messages.first(where: { $0.uid == 20 }) { store.selection = [m.id] }
                try? await Task.sleep(for: .milliseconds(150))
                await render(RootView().environment(store), size: size, appearance: appearance, to: "\(dir)/conversation-\(name).png")
            }

            // Assistant with a clean-up proposal.
            store.selection = []
            store.sidebarSelection = .dashboard
            let low = store.conversations.filter { c in [13, 16].contains(c.latest.uid) && c.latest.folder == "INBOX" }.map(\.id)
            var turn = AskTurn(question: "Clean up newsletters and notifications I don’t need")
            turn.answer = "I can archive 2 conversations: The Weekly Brief newsletter and the GitHub release notification. Neither needs a reply or has open tasks. I left Lumen Bank, Elena’s contract and everything from real people where it is."
            turn.refs = low
            turn.action = ProposedAction(kind: .archive, summary: "Archive routine newsletters and automated notifications with nothing to act on.", conversations: low, selected: Set(low))
            turn.done = true
            store.askSession.turns = [turn]
            store.showPalette = true
            await render(RootView().environment(store), size: size, appearance: .aqua, to: "\(dir)/assistant-light.png")
            store.showPalette = false

            let draft = ComposeDraft(fromEmail: "alex@example.com")
            draft.to = "Maya Chen <maya@studio.design>"
            draft.subject = "Re: Brand refresh — first round of concepts"
            draft.body = "Hi Maya,\n\nThese are fantastic — thank you. Option B is my favourite too; the wordmark feels confident without shouting. Could we see B with a slightly warmer palette before Friday’s call?\n\nBest,\nAlex"
            draft.quote = "On Monday, Maya Chen wrote:\n> Attached are three directions…"
            draft.context = "Attached are three directions"
            draft.aiTone = .friendly
            draft.aiInstruction = "love option B, ask for warmer colours"
            draft.isReply = true
            await render(ComposeView(draft: draft).environment(store), size: NSSize(width: 760, height: 560), appearance: .aqua, to: "\(dir)/compose-light.png")

            let signedOut = MailStore(demo: account, database: db)
            signedOut.account = nil
            await render(RootView().environment(signedOut), size: NSSize(width: 980, height: 820), appearance: .aqua, to: "\(dir)/onboarding-light.png")
            try? FileManager.default.removeItem(at: url)
            NSApp.terminate(nil)
        }
    }

    private static func seedInsights(_ db: Database, store: MailStore) {
        let repo = MailRepository(db: db)
        func day(_ offset: Int) -> String {
            TimelineEvent.isoDay.string(from: Calendar.current.date(byAdding: .day, value: offset, to: Date())!)
        }
        let data: [UInt32: Insight] = [
            20: Insight(priority: 3, category: "reply", summary: "Maya sent three brand directions and needs your pick before Friday’s call.", reason: "Your pick needed",
                        action: "Choose a direction and reply", due: "", needsReply: true, status: "needs_reply", dueDate: day(3),
                        timeline: [TimelineEvent(date: day(-3), text: "You kicked off the brand refresh", upcoming: false),
                                   TimelineEvent(date: day(0), text: "Maya shared three concepts", upcoming: false),
                                   TimelineEvent(date: day(3), text: "Review call with Maya", upcoming: true)]),
            19: Insight(priority: 1, category: "notification", summary: "Order #4821 has shipped and arrives Wednesday.", reason: "Delivery Wed", action: "", due: "",
                        needsReply: false, status: "scheduled", dueDate: day(1), timeline: [TimelineEvent(date: day(1), text: "Northwind package arrives", upcoming: true)]),
            18: Insight(priority: 2, category: "reply", summary: "You confirmed four for Thursday; Jonas hasn’t confirmed the booking yet.", reason: "Booking unconfirmed",
                        action: "", due: "", needsReply: false, status: "waiting", dueDate: day(2),
                        timeline: [TimelineEvent(date: day(0), text: "You confirmed four people", upcoming: false), TimelineEvent(date: day(2), text: "Ramen dinner at 7pm", upcoming: true)]),
            17: Insight(priority: 2, category: "action", summary: "You promised Priya comments on the workshop notes by Friday.", reason: "You promised",
                        action: "Send comments on onboarding and pricing", due: "", needsReply: false, status: "action", dueDate: day(3)),
            16: Insight(priority: 0, category: "notification", summary: "Letterbox v1.0 was published on GitHub.", reason: "", action: "", due: "", needsReply: false, status: "fyi"),
            15: Insight(priority: 2, category: "finance", summary: "Your September statement is ready to review.", reason: "Statement ready", action: "Check the September statement", due: "",
                        needsReply: false, status: "action"),
            14: Insight(priority: 1, category: "personal", summary: "Sam shared photos from the ridge walk.", reason: "", action: "", due: "", needsReply: true, status: "needs_reply"),
            13: Insight(priority: 0, category: "newsletter", summary: "Weekly Brief on defaults, meetings and small tools.", reason: "", action: "", due: "", needsReply: false, status: "fyi"),
            12: Insight(priority: 3, category: "deadline", summary: "Elena needs the revised contract signed; section 4 changed.", reason: "Signature needed",
                        action: "Review section 4 and sign", due: "", needsReply: true, status: "needs_reply", dueDate: day(-1),
                        timeline: [TimelineEvent(date: day(-8), text: "Elena sent the revised contract", upcoming: false), TimelineEvent(date: day(-1), text: "Signature deadline", upcoming: true)]),
        ]
        store.rebuildConversations()
        for c in store.conversations {
            guard let incoming = c.messages.last(where: { $0.folder == "INBOX" }), var i = data[incoming.uid] else { continue }
            i.latestID = c.latest.id
            repo.saveThreadInsight(i, thread: c.id)
        }
        store.threadInsights = repo.threadInsights()
        store.reindexInsights()
        store.claude = ClaudeCLI(executable: URL(fileURLWithPath: "/usr/bin/true"), model: "sonnet")
        store.aiStatus = .ready
        store.briefing = Briefing(headline: "Elena’s contract is past its signing date, and Maya needs your pick on the brand concepts before Friday’s call.",
                                  highlights: ["Sign Elena’s revised contract — section 4 changed", "Pick a brand direction and reply to Maya", "Send Priya your workshop comments by Friday"],
                                  generated: Date().addingTimeInterval(-600))
    }

    private static func render<V: View>(_ view: V, size: NSSize, appearance: NSAppearance.Name, to path: String) async {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 0, y: 0), size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.contentView = NSHostingView(rootView: view)
        window.setContentSize(size)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(ProcessInfo.processInfo.environment["SNAP_WAIT"].flatMap { Int($0) } ?? 1800))
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        guard let frameView = window.contentView?.superview else { return }
        let bounds = frameView.bounds
        if let rep = frameView.bitmapImageRepForCachingDisplay(in: bounds) {
            frameView.cacheDisplay(in: bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        window.orderOut(nil)
        window.contentView = nil
    }

    private static func seed(_ db: Database) {
        let repo = MailRepository(db: db)
        repo.replaceFolders([
            RemoteFolder(path: "INBOX", delimiter: "/", attributes: []),
            RemoteFolder(path: "Drafts", delimiter: "/", attributes: ["\\drafts"]),
            RemoteFolder(path: "Sent", delimiter: "/", attributes: ["\\sent"]),
            RemoteFolder(path: "Archive", delimiter: "/", attributes: ["\\archive"]),
            RemoteFolder(path: "Spam", delimiter: "/", attributes: ["\\junk"]),
            RemoteFolder(path: "Trash", delimiter: "/", attributes: ["\\trash"]),
            RemoteFolder(path: "Receipts", delimiter: "/", attributes: []),
        ])
        let now = Date()
        func msg(_ uid: UInt32, _ name: String, _ email: String, _ subject: String, to: String = "alex@example.com",
                 hoursAgo: Double, seen: Bool = true, flagged: Bool = false, att: Bool = false) -> FetchedSummary {
            var s = FetchedSummary()
            s.uid = uid
            s.from = [MailAddress(name: name, email: email)]
            s.to = [MailAddress(name: "", email: to)]
            s.subject = subject
            s.date = now.addingTimeInterval(-hoursAgo * 3600)
            s.flags = Set([seen ? "\\seen" : nil, flagged ? "\\flagged" : nil].compactMap { $0 })
            s.hasAttachments = att
            s.size = 4000
            s.messageID = "<m\(uid)@demo>"
            return s
        }
        let inbox = [
            msg(20, "Maya Chen", "maya@studio.design", "Brand refresh — first round of concepts", hoursAgo: 0.4, seen: false, att: true),
            msg(19, "Northwind Outfitters", "orders@northwind.com", "Your order #4821 has shipped", to: "shop@example.com", hoursAgo: 2, seen: false),
            msg(18, "Jonas Weber", "jonas@weber.dev", "Dinner Thursday?", hoursAgo: 5, flagged: true),
            msg(17, "Priya Natarajan", "priya@fieldnotes.io", "Re: Notes from the workshop", hoursAgo: 26),
            msg(16, "GitHub", "noreply@github.com", "[letterbox] New release v1.0 published", to: "alex+dev@example.com", hoursAgo: 30),
            msg(15, "Lumen Bank", "alerts@lumenbank.com", "Your monthly statement is ready", hoursAgo: 52, att: true),
            msg(14, "Sam Okafor", "sam@okafor.me", "Photos from the trip 🏔️", hoursAgo: 75, att: true),
            msg(13, "The Weekly Brief", "hello@weeklybrief.news", "Five ideas worth your Sunday", to: "shop@example.com", hoursAgo: 120),
            msg(12, "Elena Rossi", "elena@rossi.it", "Contract draft for review", hoursAgo: 200, flagged: true),
        ]
        var inboxMsgs = inbox
        inboxMsgs[0].inReplyTo = "<s103@demo>"   // Maya answered Alex's earlier note
        repo.upsert(inboxMsgs, folder: "INBOX")
        func sent(_ uid: UInt32, to name: String, _ email: String, _ subject: String, hoursAgo: Double, replyTo: String) -> FetchedSummary {
            var s = msg(uid, "Alex Rivera", "alex@example.com", subject, to: email, hoursAgo: hoursAgo)
            s.to = [MailAddress(name: name, email: email)]
            s.messageID = "<s\(uid)@demo>"
            s.inReplyTo = replyTo
            return s
        }
        repo.upsert([
            sent(101, to: "Jonas Weber", "jonas@weber.dev", "Re: Dinner Thursday?", hoursAgo: 3, replyTo: "<m18@demo>"),
            sent(102, to: "Priya Natarajan", "priya@fieldnotes.io", "Re: Notes from the workshop", hoursAgo: 20, replyTo: "<m17@demo>"),
            sent(103, to: "Maya Chen", "maya@studio.design", "Brand refresh kickoff", hoursAgo: 60, replyTo: ""),
        ], folder: "Sent")
        db.writer.run("UPDATE messages SET snippet = 'Count me in — Lena and Tom are keen too, so book for four.' WHERE folder = 'Sent' AND uid = 101")
        db.writer.run("UPDATE messages SET snippet = 'Thanks — I’ll go through these and send comments by Friday.' WHERE folder = 'Sent' AND uid = 102")
        db.writer.run("UPDATE messages SET snippet = 'Can’t wait to see what you come up with!' WHERE folder = 'Sent' AND uid = 103")
        let snippets: [UInt32: String] = [
            20: "Hi Alex — attached are three directions for the refresh. I'd love your gut reaction before Friday's call; option B is my favourite.",
            19: "Good news! Your package is on its way and should arrive Wednesday. Track your shipment any time from your account.",
            18: "There's a new ramen place near the station. Thursday at 7? I can book for four if Lena and Tom are in.",
            17: "Thanks for pulling these together. I added a few thoughts on the onboarding section and the pricing slide.",
            16: "Letterbox v1.0 is now available. This release includes a faster sync engine and alias support.",
            15: "Your statement for September is now available to view online.",
            14: "Finally sorted through everything — here are my favourites from the ridge walk. The sunrise ones came out great.",
            13: "This week: the quiet power of defaults, a field guide to good meetings, and why small tools win.",
            12: "Please find the revised contract attached. I've highlighted the changes in section 4.",
        ]
        for (uid, snippet) in snippets {
            db.writer.run("UPDATE messages SET snippet = ? WHERE folder = 'INBOX' AND uid = ?", [.text(snippet), .of(uid)])
        }
        let bodyText = """
        Hi Alex,

        Attached are three directions for the brand refresh. I'd love your gut reaction before Friday's call — option B is my favourite, but A has a warmth I keep coming back to.

        A few notes:
        • The wordmark is set in a custom cut, so it stays crisp at small sizes.
        • Colours are tuned for both light and dark backgrounds.
        • Full guidelines are at https://studio.design/letterbox

        Talk soon,
        Maya

        > On Mon, Alex wrote:
        > Can't wait to see what you've come up with!
        """
        let raw = "From: Maya Chen <maya@studio.design>\r\nSubject: Brand refresh\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n" + bodyText.replacingOccurrences(of: "\n", with: "\r\n")
        repo.saveBody(Array(raw.utf8), folder: "INBOX", uid: 19, snippet: snippets[19]!, hasAttachments: false)
        repo.saveBody(Array(raw.utf8), folder: "INBOX", uid: 20, snippet: snippets[20]!, hasAttachments: true)
        repo.saveBody(Array(raw.utf8), folder: "INBOX", uid: 13, snippet: snippets[13]!, hasAttachments: false)
        repo.updateCounts("INBOX", total: 9, unread: 2)
        repo.updateCounts("Drafts", total: 1, unread: 0)
        repo.updateCounts("Receipts", total: 4, unread: 1)
        repo.saveAlias(email: "shop@example.com", name: "", source: "detected")
        repo.saveAlias(email: "alex+dev@example.com", name: "", source: "detected")
    }
}
