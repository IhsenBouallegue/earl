import Foundation
import Testing
@testable import Earl

struct InviteParserTests {
    func names(_ text: String) -> [String] { InviteParser.parse(text).attendees.map(\.name) }

    @Test func germanOutlookInvite() {
        let text = """
        Projekt-Status Lieferplanung
        Müller, Sarah (Example AG, Team 3) <sarah.mueller@example.de>
        Do 25.09.2025 10:00 - 11:00
        Erforderlich: Weber, Tom <tom.weber@example.de>; Schäfer, Jürgen <juergen.schaefer@example.de>; Öztürk, Ayşe <ayse.oeztuerk@example.de>
        Optional: Groß, Björn <bjoern.gross@example.de>; Raum FRA-Tower 3.14 <raum-fra-st-314@example.de>
        Ort: Microsoft Teams-Besprechung; FRA-Tower 3.14

        Hallo zusammen,
        anbei die Einladung zum Status.

        ________________________________________________________________________________
        Microsoft Teams-Besprechung
        Nehmen Sie auf Ihrem Computer, in der mobilen App oder im Raumsystem teil.
        Hier klicken, um an der Besprechung teilzunehmen
        Besprechungs-ID: 312 456 789 012
        Kenncode: aB3cD4
        ________________________________________________________________________________
        """
        let r = InviteParser.parse(text)
        #expect(r.title == "Projekt-Status Lieferplanung")
        #expect(r.attendees.map(\.name) == ["Sarah Müller", "Tom Weber", "Jürgen Schäfer", "Ayşe Öztürk", "Björn Groß"])
        #expect(r.attendees.first?.email == "sarah.mueller@example.de")
    }

    @Test func englishOutlookHeaders() {
        let text = """
        Subject: Q3 Architecture Review
        From: Sarah Miller <sarah.miller@contoso.com>
        Required: John Smith <john.smith@contoso.com>; Doe, Jane <jane.doe@contoso.com>
        Optional: Conference Room 4B <room4b@contoso.com>
        When: Thursday, 25 September 2025 14:00-15:00
        Where: Microsoft Teams Meeting
        """
        let r = InviteParser.parse(text)
        #expect(r.title == "Q3 Architecture Review")
        #expect(r.attendees.map(\.name) == ["Sarah Miller", "John Smith", "Jane Doe"])
    }

    @Test func semicolonListWithFlippedNames() {
        #expect(names("Müller, Sarah; Weber, Tom; Schröder, Anna-Lena")
                == ["Sarah Müller", "Tom Weber", "Anna-Lena Schröder"])
    }

    @Test func mixedFormatsFromSpec() {
        let r = InviteParser.parse("Müller, Sarah <sarah.mueller@example.de>; Tom Weber; jens.koehler@example.de")
        #expect(r.attendees.map(\.name) == ["Sarah Müller", "Tom Weber", "Jens Koehler"])
        #expect(r.attendees.map(\.email) == ["sarah.mueller@example.de", nil, "jens.koehler@example.de"])
    }

    @Test func oneNamePerLine() {
        let text = """
        Sarah Müller
        Tom Weber
        Özlem Yıldız
        Hans-Peter von der Heide
        """
        #expect(names(text) == ["Sarah Müller", "Tom Weber", "Özlem Yıldız", "Hans-Peter von der Heide"])
        #expect(InviteParser.parse(text).title == nil)
    }

    @Test func bareEmailsCommaSeparated() {
        #expect(names("sarah.mueller@example.de, tom.weber@example.de, noreply@example.de")
                == ["Sarah Mueller", "Tom Weber"])
    }

    @Test func duplicatesAreMergedAcrossSpellings() {
        let text = """
        Von: Müller, Sarah <sarah.mueller@example.de>
        An: sarah.mueller@example.de; Weber, Tom; Tom Weber <tom.weber@example.de>
        Cc: Sarah Mueller
        """
        let r = InviteParser.parse(text)
        #expect(r.attendees.map(\.name) == ["Sarah Müller", "Tom Weber"])
        #expect(r.attendees.map(\.email) == ["sarah.mueller@example.de", "tom.weber@example.de"])
    }

    @Test func derivedNameGivesWayToWrittenOne() {
        let r = InviteParser.parse("jurgen.schafer@example.de; Schäfer, Jürgen <jurgen.schafer@example.de>")
        #expect(r.attendees.map(\.name) == ["Jürgen Schäfer"])
    }

    @Test func roomsAndResourcesAreSkipped() {
        let text = """
        Erforderlich: Weber, Tom <tom.weber@example.de>; Raum 3.14; FRA-Tower-Room; Besprechungsraum Berlin <bespr.berlin@example.de>; Beamer Ressource <res-beamer-7@example.de>
        Optional: Graumann, Lisa <lisa.graumann@example.de>; Konferenzraum Mainz
        """
        #expect(names(text) == ["Tom Weber", "Lisa Graumann"])
    }

    @Test func teamsJoinBlockInPlainListIsIgnored() {
        let text = """
        Anna Schmidt
        Peter Krüger
        ________________________________________________________________________________
        Microsoft Teams meeting
        Join on your computer, mobile app or room device
        Click here to join the meeting
        Meeting ID: 312 456 789 012
        Passcode: aB3cD4
        Learn More | Meeting options
        ________________________________________________________________________________
        """
        #expect(names(text) == ["Anna Schmidt", "Peter Krüger"])
    }

    @Test func forwardedSubjectPrefixesAreStripped() {
        let text = """
        Betreff: WG: Einladung: Sprint Review Stellwerk
        Erforderlich: Hoffmann, Käthe
        """
        let r = InviteParser.parse(text)
        #expect(r.title == "Sprint Review Stellwerk")
        #expect(r.attendees.map(\.name) == ["Käthe Hoffmann"])
    }

    @Test func wrappedAttendeeLinesContinue() {
        let text = """
        Required: Weber, Tom <tom.weber@example.de>; Müller, Sarah <sarah.mueller@example.de>;
        Lange, Fritz <fritz.lange@example.de>
        When: Friday 26 September 2025 09:00-09:30

        Please prepare the numbers, Fritz Lange knows the details.
        """
        #expect(names(text) == ["Tom Weber", "Sarah Müller", "Fritz Lange"])
    }

    @Test func quotedNamesAndOrgSuffixes() {
        let text = #"'Weber, Tom (Example GmbH)' <tom.weber@example.de>; "Anna Schmidt [extern]" <anna.schmidt@partner.de>"#
        #expect(names(text) == ["Tom Weber", "Anna Schmidt"])
    }

    @Test func teamsRosterWithRoles() {
        let text = """
        Müller, Sarah (Example AG)
        Organizer
        Weber, Tom
        Presenter
        Lena Fischer (Guest)
        """
        #expect(names(text) == ["Sarah Müller", "Tom Weber", "Lena Fischer"])
    }

    @Test func plainCommaListOfFullNames() {
        #expect(names("Sarah Müller, Tom Weber, Anna Schmidt") == ["Sarah Müller", "Tom Weber", "Anna Schmidt"])
    }

    @Test func googleInvitationSubject() {
        let r = InviteParser.parse("""
        Invitation: Roadmap Sync @ Mon 29 Sep 2025 10am - 11am (CEST) (tom.weber@gmail.com)
        Organizer: Tom Weber <tom.weber@gmail.com>
        Guests: sarah.mueller@gmail.com
        """)
        #expect(r.title == "Roadmap Sync")
        #expect(r.attendees.map(\.name) == ["Tom Weber", "Sarah Mueller"])
    }

    @Test func userIsMarked() {
        let r = InviteParser.parse("Weber, Tom; Müller, Sarah", userName: "Sarah Mueller")
        #expect(r.attendees.map(\.isMe) == [false, true])
    }

    @Test func freeTextFindsNothing() {
        #expect(names("Hallo zusammen,\nbitte die Zahlen mitbringen.") == [])
    }
}
