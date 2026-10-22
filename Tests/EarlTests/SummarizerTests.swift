import Testing
@testable import Earl

struct SummarizerTests {
    @Test func extractsTitle() {
        let result = Summarizer.parse("TITLE: Weekly sync\n\n## Summary\n- Things happened")
        #expect(result.title == "Weekly sync")
        #expect(result.headline == nil)
        #expect(result.markdown.hasPrefix("## Summary"))
    }

    // U-2
    @Test func extractsHeadline() {
        let result = Summarizer.parse(
            "TITLE: Weekly sync\nHEADLINE: Onboarding ships to 20 % on October 6\n\n## Summary\n- Things happened")
        #expect(result.title == "Weekly sync")
        #expect(result.headline == "Onboarding ships to 20 % on October 6")
        #expect(result.markdown == "## Summary\n- Things happened")
    }

    @Test func headlineToleratesMarkdownAndCase() {
        let result = Summarizer.parse(
            "TITLE: Lieferplan\n  Headline: **\"Rollout startet am 3. November\"**\n\n## Summary\n- x")
        #expect(result.title == "Lieferplan")
        #expect(result.headline == "Rollout startet am 3. November")
        #expect(!result.markdown.contains("Headline"))
    }

    @Test func headlineWithoutTitleAndEmptyHeadline() {
        #expect(Summarizer.parse("HEADLINE: Ships Monday\n## Summary\n- x").headline == "Ships Monday")
        #expect(Summarizer.parse("HEADLINE: Ships Monday\n## Summary\n- x").title == nil)
        #expect(Summarizer.parse("TITLE: A\nHEADLINE:\n## Summary\n- x").headline == nil)
    }

    @Test func notesStayValidWithAndWithoutHeadline() {
        #expect(NotesCheck.isValid("TITLE: Sync\nHEADLINE: We ship\n\n## Summary\n- Done."))
        #expect(NotesCheck.isValid("TITLE: Sync\n\n## Summary\n- Done."))
        #expect(!NotesCheck.isValid("TITLE: Sync\nHEADLINE: We ship"))
    }

    @Test func promptAsksForHeadlineUnderTitle() throws {
        let text = NotesPrompt().final(intro: "", material: "Transcript:\n\nMe: hi")
        let title = try #require(text.range(of: "TITLE:"))
        let headline = try #require(text.range(of: "HEADLINE:"))
        #expect(title.upperBound < headline.lowerBound)
        #expect(text.contains("at most 12 words"))
    }
}
