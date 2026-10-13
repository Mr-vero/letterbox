import XCTest
@testable import Letterbox

final class ThreadTests: XCTestCase {
    private func m(_ folder: String, _ uid: UInt32, from: String, to: String, subject: String, hoursAgo: Double,
                   id: String, inReplyTo: String? = nil, refs: String? = nil) -> MessageSummary {
        MessageSummary(folder: folder, uid: uid, messageID: id, subject: subject, fromName: "", fromEmail: from,
                       to: [MailAddress(name: "", email: to)], cc: [], replyTo: [], deliveredTo: [],
                       date: Date().addingTimeInterval(-hoursAgo * 3600), seen: true, flagged: false, answered: false,
                       size: 1, hasAttachments: false, snippet: "", inReplyTo: inReplyTo, references: refs)
    }

    func testHeaderThreadingAndReplyState() {
        let me: Set<String> = ["me@mail.com"]
        let msgs = [
            m("INBOX", 1, from: "ann@x.com", to: "me@mail.com", subject: "Plans", hoursAgo: 50, id: "<a1@x>"),
            m("Sent", 2, from: "me@mail.com", to: "ann@x.com", subject: "Re: Plans", hoursAgo: 40, id: "<b1@mail>", inReplyTo: "<a1@x>"),
            m("INBOX", 3, from: "ann@x.com", to: "me@mail.com", subject: "Re: Plans", hoursAgo: 10, id: "<a2@x>", inReplyTo: "<b1@mail>", refs: "<a1@x> <b1@mail>"),
            m("INBOX", 4, from: "bob@y.com", to: "me@mail.com", subject: "Invoice", hoursAgo: 5, id: "<c1@y>"),
            m("Sent", 5, from: "me@mail.com", to: "bob@y.com", subject: "Re: Invoice", hoursAgo: 1, id: "<d1@mail>", inReplyTo: "<c1@y>"),
        ]
        let convs = ThreadBuilder.build(msgs, me: me, sentFolder: "Sent")
        XCTAssertEqual(convs.count, 2)
        let plans = convs.first { $0.subject == "Plans" }!
        XCTAssertEqual(plans.count, 3)
        XCTAssertFalse(plans.lastFromMe, "Ann wrote last — the ball is in my court")
        XCTAssertNotNil(plans.myLastReply)
        let invoice = convs.first { $0.subject == "Invoice" }!
        XCTAssertTrue(invoice.lastFromMe, "I replied last — waiting on Bob")
        XCTAssertEqual(invoice.counterpart.email, "bob@y.com")
    }

    func testSubjectFallbackJoinsHeaderlessReply() {
        let msgs = [
            m("INBOX", 1, from: "ann@x.com", to: "me@mail.com", subject: "Quarterly report", hoursAgo: 30, id: "<a1@x>"),
            m("Sent", 2, from: "me@mail.com", to: "ann@x.com", subject: "RE: Quarterly report", hoursAgo: 2, id: "<z@mail>"),
            m("INBOX", 3, from: "carl@z.com", to: "me@mail.com", subject: "Re: Quarterly report", hoursAgo: 1, id: "<q@z>"),
        ]
        let convs = ThreadBuilder.build(msgs, me: ["me@mail.com"], sentFolder: "Sent")
        XCTAssertEqual(convs.first { $0.messages.contains { $0.uid == 2 } }?.count, 2)
        XCTAssertEqual(convs.count, 2, "Carl shares no participants, so he stays separate")
    }

    func testNewContentStripsQuotes() {
        let text = "Sounds good, see you then.\n\nOn Mon, 13 Oct 2026, Ann wrote:\n> Shall we meet at 3?\n> Thanks"
        XCTAssertEqual(ThreadBuilder.newContent(text), "Sounds good, see you then.")
    }
}
