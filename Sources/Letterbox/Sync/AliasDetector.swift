import Foundation

/// IMAP doesn't expose a provider's alias list, so we infer aliases from mail that
/// actually reached this mailbox: envelope recipients, addresses we've sent from,
/// plus-addresses, and same-family addresses that received mail without the primary
/// address. mail.com is special-cased because its aliases span ~200 domains.
enum AliasDetector {
    static let mailComDomains = Set<String>([
        "mail.com", "email.com", "usa.com", "myself.com", "consultant.com", "post.com", "europe.com", "asia.com",
        "iname.com", "writeme.com", "dr.com", "engineer.com", "cheerful.com", "accountant.com", "techie.com",
        "linuxmail.org", "musician.org", "contractor.net", "financier.com", "workmail.com", "null.net",
        "cyberservices.com", "activist.com", "adexec.com", "africamail.com", "aircraftmail.com", "alumni.com",
        "alumnidirector.com", "angelic.com", "appraiser.net", "archaeologist.com", "arcticmail.com", "artlover.com",
        "asia-mail.com", "atheist.com", "auctioneer.net", "australiamail.com", "bartender.net", "bikerider.com",
        "birdlover.com", "brazilmail.com", "britishintelligence.co.uk", "chef.net", "chemist.com", "chinamail.com",
        "clerk.com", "collector.org", "columnist.com", "comic.com", "computer4u.com", "consultant.com",
        "counsellor.com", "cutey.com", "dallasmail.com", "dbzmail.com", "deliveryman.com", "diplomats.com",
        "disciples.com", "doctor.com", "doglover.com", "dublin.com", "dutchmail.com", "elvisfan.com", "englandmail.com",
        "europemail.com", "execs.com", "fastservice.com", "fireman.net", "gardener.com", "germanymail.com",
        "graduate.org", "graphic-designer.com", "groupmail.com", "hackermail.com", "hairdresser.net", "hilarious.com",
        "hockeymail.com", "homemail.com", "hot-shot.com", "hour.com", "humanoid.net", "illinoisstate.com",
        "innocent.com", "inorbit.com", "instruction.com", "instructor.net", "insurer.com", "irelandmail.com",
        "italymail.com", "japan.com", "journalist.com", "keromail.com", "kittymail.com", "koreamail.com", "lawyer.com",
        "legislator.com", "loveable.com", "lovecat.com", "mad.scientist.com", "madonnafan.com", "madrid.com",
        "marchmail.com", "mexicomail.com", "mindless.com", "minister.com", "mobsters.com", "monarchy.com", "moscowmail.com",
        "munich.com", "nonpartisan.com", "nycmail.com", "optician.com", "orthodontist.net", "pediatrician.com",
        "petlover.com", "photographer.net", "physicist.net", "planetmail.com", "planetmail.net", "polandmail.com",
        "politician.com", "presidency.com", "priest.com", "programmer.net", "protestant.com", "publicist.com",
        "qualityservice.com", "radiologist.net", "ravemail.com", "realtyagent.com", "reborn.com", "reggaefan.com",
        "religious.com", "repairman.com", "representative.com", "rescueteam.com", "revenue.com", "rocketship.com",
        "safrica.com", "saintly.com", "salesperson.net", "samerica.com", "sanfranmail.com", "scotlandmail.com",
        "secretary.net", "socialworker.net", "sociologist.com", "solution4u.com", "songwriter.net", "spainmail.com",
        "surgical.net", "swedenmail.com", "swissmail.com", "teachers.org", "tech-center.com", "theplate.com",
        "therapist.net", "toke.com", "toothfairy.com", "torontomail.com", "tvstar.com", "umpire.com", "usa.com",
        "uymail.com", "worker.com", "workmail.com", "yours.com", "2trom.com", "berlin.com",
    ])

    /// Shared consumer domains where other people's addresses share our domain.
    static let genericDomains: Set<String> = [
        "gmail.com", "googlemail.com", "icloud.com", "me.com", "mac.com", "yahoo.com", "outlook.com", "hotmail.com",
        "live.com", "aol.com", "fastmail.com", "proton.me", "protonmail.com", "zoho.com", "gmx.com",
    ]

    struct Candidate {
        let email: String
        var name: String
        var score: Int
    }

    static func detect(_ e: MailRepository.AliasEvidence, primary: String) -> [Candidate] {
        let primary = primary.lowercased()
        let primaryDomain = primary.split(separator: "@").last.map(String.init) ?? ""
        var candidates: [String: Candidate] = [:]

        func bump(_ email: String, _ score: Int, name: String = "") {
            let key = email.lowercased().trimmingCharacters(in: .whitespaces)
            guard key != primary, key.contains("@"), !key.hasPrefix("undisclosed") else { return }
            var c = candidates[key] ?? Candidate(email: key, name: "", score: 0)
            c.score += score
            if c.name.isEmpty && !name.isEmpty { c.name = name }
            candidates[key] = c
        }

        let primaryLocal = primary.split(separator: "@").first.map(String.init) ?? ""
        let mailComFamily = mailComDomains.contains(primaryDomain)
        func isFamily(_ email: String) -> Bool {
            let parts = email.lowercased().split(separator: "@")
            guard parts.count == 2 else { return false }
            let (local, domain) = (String(parts[0]), String(parts[1]))
            if local.hasPrefix(primaryLocal + "+") && domain == primaryDomain { return true }
            if domain == primaryDomain && !genericDomains.contains(domain) { return true }
            return mailComFamily && mailComDomains.contains(domain)
        }
        /// For the weaker "To:" heuristic, skip own-domain addresses: on a company domain they're usually colleagues.
        func isLikelyAlias(_ email: String) -> Bool {
            let domain = email.lowercased().split(separator: "@").last.map(String.init) ?? ""
            return isFamily(email) && (domain != primaryDomain || email.lowercased().hasPrefix(primaryLocal + "+") || mailComFamily)
        }

        for addr in e.delivered where isFamily(addr) { bump(addr, 10) }
        for from in e.sentFrom where isFamily(from.email) { bump(from.email, 10, name: from.name) }
        for msg in e.received {
            let all = Set(msg.recipients.map { $0.email.lowercased() } + msg.delivered)
            guard !all.contains(primary) else { continue }
            for addr in msg.recipients where isLikelyAlias(addr.email) { bump(addr.email, 3) }
        }
        return candidates.values.filter { $0.score >= 3 }.sorted { $0.score > $1.score }
    }
}
