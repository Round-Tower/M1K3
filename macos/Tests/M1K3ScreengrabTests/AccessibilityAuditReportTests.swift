//
//  AccessibilityAuditReportTests.swift
//  M1K3ScreengrabTests
//
//  Signed: Kev + claude-fable-5.2, 2026-11-13, Confidence 0.85 (pinned), Prior: Unknown
//  Review: Kev + claude-fable-5.2, 2026-11-14 — pins `elementName`: the first Mac run left 59 of 78
//  findings as "(unnamed element)", which nobody could act on.
//

@testable import M1K3Screengrab
import Testing

struct AccessibilityAuditReportTests {
    private func finding(
        _ screen: String, _ kind: String, _ element: String, _ detail: String = "detail"
    ) -> AccessibilityAuditFinding {
        AccessibilityAuditFinding(screen: screen, kind: kind, element: element, detail: detail)
    }

    @Test("no findings reads as a clean run, not an empty file")
    func cleanRun() {
        #expect(AccessibilityAuditReport.summary([]) == "0 issues")
        #expect(AccessibilityAuditReport.render([]) == "0 issues\n")
    }

    @Test("the summary counts issues, screens and each kind, most frequent first")
    func summaryCounts() {
        let findings = [
            finding("chat", "contrast", "Send"),
            finding("chat", "contrast", "Stop"),
            finding("settings", "contrast", "Reset"),
            finding("settings", "description", "plus"),
        ]
        #expect(AccessibilityAuditReport.summary(findings) == "4 issues on 2 screens: contrast 3, description 1")
    }

    @Test("one issue on one screen is singular")
    func singular() {
        #expect(AccessibilityAuditReport.summary([finding("chat", "contrast", "Send")])
            == "1 issue on 1 screen: contrast 1")
    }

    @Test("the same element flagged twice for the same thing on one screen is one finding")
    func duplicatesCollapse() {
        let twice = [finding("chat", "contrast", "Send"), finding("chat", "contrast", "Send")]
        #expect(AccessibilityAuditReport.unique(twice).count == 1)
        #expect(AccessibilityAuditReport.summary(twice) == "1 issue on 1 screen: contrast 1")
    }

    @Test("the same element on two screens, or for two kinds, stays two findings")
    func distinctStayDistinct() {
        let findings = [
            finding("chat", "contrast", "Send"),
            finding("voice", "contrast", "Send"),
            finding("chat", "description", "Send"),
        ]
        #expect(AccessibilityAuditReport.unique(findings).count == 3)
    }

    @Test("two unnamed elements with the same issue in different places are two findings")
    func unnamedElementsStayApart() {
        let first = AccessibilityAuditFinding(
            screen: "chat", kind: "description", element: "", detail: "No description", place: "{{0, 0}, {44, 44}}"
        )
        var second = first
        second.place = "{{60, 0}, {44, 44}}"
        #expect(AccessibilityAuditReport.unique([first, second, first]).count == 2)
        #expect(AccessibilityAuditReport.summary([first, second, first]) == "2 issues on 1 screen: description 2")
    }

    @Test("kinds with the same count are listed by name, so the summary never reorders between runs")
    func summaryTieBreak() {
        let findings = [finding("chat", "trait", "A"), finding("chat", "contrast", "B"), finding("chat", "hit region", "C")]
        #expect(AccessibilityAuditReport.summary(findings) == "3 issues on 1 screen: contrast 1, hit region 1, trait 1")
    }

    @Test("the report groups by screen in first-seen order, one line per finding")
    func renderGroups() {
        let findings = [
            finding("settings", "contrast", "Reset", "Contrast failed"),
            finding("chat", "description", "plus", "Element has no description"),
            finding("settings", "hit region", "Close", "Hit area is too small"),
        ]
        let expected = """
        3 issues on 2 screens: contrast 1, description 1, hit region 1

        ## settings (2)
        - [contrast] Reset: Contrast failed
        - [hit region] Close: Hit area is too small

        ## chat (1)
        - [description] plus: Element has no description

        """
        #expect(AccessibilityAuditReport.render(findings) == expected)
    }

    @Test("an element with no name is still a line a reader can act on")
    func unnamedElement() {
        let report = AccessibilityAuditReport.render([finding("chat", "description", "  ", "Element has no description")])
        #expect(report.contains("- [description] (unnamed element): Element has no description"))
    }

    @Test("a multi-line detail is folded onto the finding's one line")
    func detailFolded() {
        let report = AccessibilityAuditReport.render([finding("chat", "contrast", "Send", "Contrast failed\nRatio 2.1")])
        #expect(report.contains("- [contrast] Send: Contrast failed Ratio 2.1"))
    }

    @Test("an element with a label is named by it")
    func elementNameUsesLabel() {
        #expect(AccessibilityAuditReport.elementName(
            label: "Send", identifier: "chat.send", title: "", value: "", type: "button", frame: "{{0, 0}, {44, 44}}"
        ) == "Send")
    }

    @Test("an identifier is not a spoken name: it places the element, it does not stand in for a label")
    func elementNameShowsIdentifierAsAPlace() {
        #expect(AccessibilityAuditReport.elementName(
            label: " ", identifier: "bolt.fill", title: "Lil M1K3", value: "", type: "menu button", frame: "{{0, 0}, {41, 36}}"
        ) == "menu button #bolt.fill \"Lil M1K3\" at {{0, 0}, {41, 36}}")
    }

    @Test("an element with no name is told apart by what it is, what it shows and where it sits")
    func elementNameFallsBackToTypeAndPlace() {
        #expect(AccessibilityAuditReport.elementName(
            label: "", identifier: "", title: "", value: "", type: "image", frame: "{{12, 40}, {16, 16}}"
        ) == "image at {{12, 40}, {16, 16}}")
        #expect(AccessibilityAuditReport.elementName(
            label: "", identifier: "", title: "", value: "On this Mac\nonly", type: "static text", frame: "{{0, 0}, {90, 14}}"
        ) == "static text \"On this Mac only\" at {{0, 0}, {90, 14}}")
        #expect(AccessibilityAuditReport.elementName(
            label: "", identifier: "", title: "Reset", value: "ignored", type: "button", frame: ""
        ) == "button \"Reset\"")
    }

    @Test("a long value is cut so a finding stays one readable line")
    func elementNameCutsLongText() {
        let name = AccessibilityAuditReport.elementName(
            label: "", identifier: "", title: "", value: String(repeating: "a", count: 200), type: "static text", frame: ""
        )
        #expect(name == "static text \"" + String(repeating: "a", count: 60) + "…\"")
    }

    @Test("nothing known at all still reads as unnamed")
    func elementNameEmpty() {
        #expect(AccessibilityAuditReport.elementName(label: "", identifier: "", title: "", value: "", type: "", frame: "") == "")
    }
}
