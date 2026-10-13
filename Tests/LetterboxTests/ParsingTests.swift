import XCTest
@testable import Letterbox

final class ParsingTests: XCTestCase {
    func testIMAPFetchWithLiteralAndBrackets() {
        let line = Array("* 12 FETCH (UID 345 FLAGS (\\Seen \\Flagged) BODY[HEADER.FIELDS (DELIVERED-TO)] {28}\r\nDelivered-To: me@usa.com\r\n\r\n RFC822.SIZE 99)".utf8)
        let v = IMAPParser.parse(line)
        XCTAssertEqual(v.count, 4)
        let items = v[3].items
        XCTAssertEqual(items[0].text, "UID")
        XCTAssertEqual(items[1].int, 345)
        XCTAssertEqual(items[3].items.compactMap(\.text), ["\\Seen", "\\Flagged"])
        XCTAssertEqual(items[4].text, "BODY[HEADER.FIELDS (DELIVERED-TO)]")
        XCTAssertEqual(items[5].bytes?.count, 28)
        XCTAssertEqual(items[7].int, 99)
    }

    func testEncodedWordsAcrossChunks() {
        // "Grüße 🎉" split mid-character across two base64 words.
        let s = "=?UTF-8?B?R3LDvMOfZSDw?= =?UTF-8?B?n46J?="
        XCTAssertEqual(EncodedWords.decode(s), "Grüße 🎉")
        XCTAssertEqual(EncodedWords.decode("=?iso-8859-1?Q?caf=E9_cr=E8me?= now"), "café crème now")
        XCTAssertEqual(EncodedWords.decode("Plain subject"), "Plain subject")
    }

    func testModifiedUTF7() {
        XCTAssertEqual(ModifiedUTF7.decode("Entw&APw-rfe"), "Entwürfe")
        XCTAssertEqual(ModifiedUTF7.decode("A&-B"), "A&B")
    }

    func testMultipartAlternativeWithAttachment() {
        let raw = """
        From: Ann <ann@example.com>\r
        Subject: =?UTF-8?Q?Hello_w=C3=B6rld?=\r
        Content-Type: multipart/mixed; boundary="outer"\r
        \r
        --outer\r
        Content-Type: multipart/alternative; boundary=inner\r
        \r
        --inner\r
        Content-Type: text/plain; charset=utf-8\r
        Content-Transfer-Encoding: quoted-printable\r
        \r
        Hi there, this is a long line that wraps with a soft =\r
        break and caf=C3=A9.\r
        --inner\r
        Content-Type: text/html; charset=utf-8\r
        \r
        <p>Hi <b>there</b></p>\r
        --inner--\r
        --outer\r
        Content-Type: application/pdf; name="report.pdf"\r
        Content-Disposition: attachment; filename*=utf-8''r%C3%A9sum%C3%A9.pdf\r
        Content-Transfer-Encoding: base64\r
        \r
        JVBERi0xLjQK\r
        --outer--\r
        """
        let m = MessageParser.parse(Array(raw.utf8))
        XCTAssertEqual(m.headers.decoded("Subject"), "Hello wörld")
        XCTAssertEqual(m.text, "Hi there, this is a long line that wraps with a soft break and café.")
        XCTAssertEqual(m.html, "<p>Hi <b>there</b></p>")
        XCTAssertEqual(m.attachments.count, 1)
        XCTAssertEqual(m.attachments.first?.filename, "résumé.pdf")
        XCTAssertEqual(String(data: m.attachments[0].data, encoding: .ascii), "%PDF-1.4\n")
        XCTAssertTrue(m.snippet.hasPrefix("Hi there"))
    }

    func testHTMLSnippetStripsNoise() {
        let html = "<html><head><style>p{}</style></head><body>&zwnj;&nbsp;<p>Your order&#8217;s shipped</p></body></html>"
        XCTAssertEqual(HTMLText.squash(HTMLText.plainText(html)), "Your order’s shipped")
    }

    func testBuilderRoundTrip() {
        let out = OutgoingMessage(from: MailAddress(name: "Zoë", email: "me@mail.com"),
                                  to: [MailAddress(name: "Bob, Jr.", email: "bob@x.com")],
                                  subject: "Über plans", body: "Line one\n.dot line\nnaïve")
        let (bytes, _) = MessageBuilder.build(out)
        let parsed = MessageParser.parse(bytes)
        XCTAssertEqual(parsed.headers.decoded("Subject"), "Über plans")
        XCTAssertEqual(parsed.text, "Line one\r\n.dot line\r\nnaïve")
        XCTAssertEqual(MailAddress.parseList(parsed.headers["To"] ?? "").first?.email, "bob@x.com")
        XCTAssertEqual(MailAddress.parseList(parsed.headers["To"] ?? "").first?.name, "Bob, Jr.")
    }

    func testAddressListParsing() {
        let list = MailAddress.parseList("\"Doe, Jane\" <jane@x.com>, bob@y.com; Al <al@z.org>")
        XCTAssertEqual(list.map(\.email), ["jane@x.com", "bob@y.com", "al@z.org"])
        XCTAssertEqual(list[0].name, "Doe, Jane")
    }

    func testAliasDetection() {
        var e = MailRepository.AliasEvidence()
        e.received = [
            ([MailAddress(name: "", email: "Shop@Usa.com")], []),           // alias: primary absent
            ([MailAddress(name: "", email: "me@mail.com"), MailAddress(name: "", email: "friend@mail.com")], []), // friend, primary present
            ([MailAddress(name: "", email: "news@gmail.com")], []),         // not mail.com family
        ]
        e.delivered = ["work@engineer.com"]
        let found = AliasDetector.detect(e, primary: "me@mail.com").map(\.email)
        XCTAssertEqual(Set(found), ["shop@usa.com", "work@engineer.com"])
    }

    func testUIDSetCompression() {
        XCTAssertEqual(IMAPClient.uidSet([5, 1, 2, 3, 9, 10]), "1:3,5,9:10")
    }
}
