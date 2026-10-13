import XCTest
@testable import Letterbox

/// Exercises the real Claude CLI. Run with LETTERBOX_LIVE_AI=1.
final class LiveClaudeTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LETTERBOX_LIVE_AI"] == "1")
    }

    private func cli() throws -> ClaudeCLI {
        let url = try XCTUnwrap(ClaudeCLI.locate())
        return ClaudeCLI(executable: url, model: "sonnet")
    }

    private func m(_ folder: String, _ uid: UInt32, from: String, name: String, to: String, subject: String, hoursAgo: Double,
                   id: String, inReplyTo: String? = nil, snippet: String) -> MessageSummary {
        MessageSummary(folder: folder, uid: uid, messageID: id, subject: subject, fromName: name, fromEmail: from,
                       to: [MailAddress(name: "", email: to)], cc: [], replyTo: [], deliveredTo: [],
                       date: Date().addingTimeInterval(-hoursAgo * 3600), seen: true, flagged: false, answered: false,
                       size: 1, hasAttachments: false, snippet: snippet, inReplyTo: inReplyTo, references: nil)
    }

    func testConversationTriageUnderstandsReplies() async throws {
        let msgs = [
            m("INBOX", 1, from: "elena@rossi.it", name: "Elena Rossi", to: "me@mail.com", subject: "Contract", hoursAgo: 30, id: "<e1@x>",
              snippet: "Attached is the revised contract. I need it signed by Wednesday or the deal lapses."),
            m("INBOX", 2, from: "jonas@weber.dev", name: "Jonas", to: "me@mail.com", subject: "Dinner Thursday?", hoursAgo: 20, id: "<j1@x>",
              snippet: "Ramen Thursday at 7? Can you confirm how many of you are coming so I can book?"),
            m("Sent", 3, from: "me@mail.com", name: "Me", to: "jonas@weber.dev", subject: "Re: Dinner Thursday?", hoursAgo: 2, id: "<j2@me>",
              inReplyTo: "<j1@x>", snippet: "Yes! Four of us. Can you book and confirm the time?"),
        ]
        let convs = ThreadBuilder.build(msgs, me: ["me@mail.com"], sentFolder: "Sent")
        let blocks = convs.enumerated().map { Assistant.threadBlock(id: "c\($0.offset + 1)", conversation: $0.element, bodies: [:]) }
        let r = try await cli().structured(Assistant.ThreadResponse.self, prompt: Assistant.threadPrompt(blocks),
                                           system: Assistant.threadSystem(user: "Test User <me@mail.com>"), schema: Assistant.threadSchema)
        for item in r.items {
            let c = convs[Int(item.id.dropFirst())! - 1]
            print("THREAD:", c.subject, "→", item.status, "p\(item.priority)", item.summary, "| due", item.due_date ?? "", "| timeline", item.timeline?.map { "\($0.date) \($0.text)\($0.upcoming ? " (upcoming)" : "")" } ?? [])
            if c.subject.contains("Dinner") { XCTAssertEqual(item.status, "waiting") }
            if c.subject.contains("Contract") { XCTAssertNotEqual(item.status, "waiting"); XCTAssertGreaterThanOrEqual(item.priority, 2) }
        }
    }

    func testStreamingReply() async throws {
        var text = ""
        for try await chunk in try cli().stream(
            prompt: Assistant.replyPrompt(from: "Jonas <jonas@weber.dev>", subject: "Dinner Thursday?", date: Date(),
                                          body: "Ramen Thursday at 7? I can book for four.", instruction: "yes, count me in", tone: .friendly),
            system: Assistant.replySystem(name: "Alex Rivera", email: "alex@mail.com")) {
            text += chunk
        }
        print("REPLY:\n\(text)")
        XCTAssertTrue(text.lowercased().contains("jonas"))
        XCTAssertGreaterThan(text.count, 20)
    }

    func testCleanupProposalIsConservative() async throws {
        let index = """
        c1 | 2026-10-13 | Maya Chen <maya@studio.design> | "Brand refresh" | 2 msg | last by THEM | needs_reply p3 reply | Maya needs your pick before Friday
        c2 | 2026-10-12 | The Weekly Brief <hello@weeklybrief.news> | "Five ideas for Sunday" | 1 msg | last by THEM | fyi p0 newsletter | Weekly newsletter
        c3 | 2026-10-11 | Shoply <deals@shoply.com> | "48h flash sale" | 1 msg | last by THEM | fyi p0 promotion | Discount promotion
        c4 | 2026-10-10 | Lumen Bank <alerts@lumenbank.com> | "Statement ready" | 1 msg | last by THEM | action p2 finance | September statement ready
        c5 | 2026-10-09 | GitHub <noreply@github.com> | "New sign-in to your account" | 1 msg | last by THEM | fyi p1 notification | Security alert: new sign-in
        c6 | 2026-10-08 | Medium Digest <noreply@medium.com> | "Stories for you" | 1 msg | last by THEM | fyi p0 newsletter | Daily digest
        """
        let r = try await cli().structured(Assistant.AnswerResponse.self,
                                           prompt: "Conversation index:\n\(index)\n\nRequest: clean up newsletters and promotions I don't need",
                                           system: Assistant.answerSystem(user: "Test User", today: "Tuesday 13 October 2026"),
                                           schema: Assistant.answerSchema)
        print("CLEANUP:", r.action.type, r.action.conversations, "—", r.action.summary, "\nANSWER:", r.answer)
        XCTAssertNotEqual(r.action.type, "none")
        XCTAssertTrue(Set(r.action.conversations).isSuperset(of: ["c2", "c3", "c6"]))
        XCTAssertTrue(Set(r.action.conversations).isDisjoint(with: ["c1", "c4", "c5"]))
    }
}
