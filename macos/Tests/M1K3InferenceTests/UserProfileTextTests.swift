//
//  UserProfileTextTests.swift
//  M1K3InferenceTests
//
//  Signed: Kev + claude-fable-5.1, 2026-10-10, Confidence 0.9, Prior: none (new file).

@testable import M1K3Inference
import Testing

struct UserProfileTextTests {
    @Test("the Name line is rewritten and the notes below it are untouched")
    func rewritesOnlyTheNameLine() {
        let profile = "Name: Kev.\nLikes maps.\nName: not this one."
        #expect(UserProfileText.rewritingName("Kevin", in: profile) == "Name: Kevin.\nLikes maps.\nName: not this one.")
    }

    @Test("a profile whose first line is not a Name line is left alone")
    func leavesARewrittenProfileAlone() {
        #expect(UserProfileText.rewritingName("Kevin", in: "I am Kev.\nLikes maps.") == nil)
        #expect(UserProfileText.rewritingName("Kevin", in: "") == nil)
    }

    @Test("the same name, or an empty one, changes nothing")
    func noOpForSameOrEmpty() {
        #expect(UserProfileText.rewritingName("Kev", in: "Name: Kev.\nLikes maps.") == nil)
        #expect(UserProfileText.rewritingName("  Kev ", in: "Name: Kev.") == nil)
        #expect(UserProfileText.rewritingName("   ", in: "Name: Kev.") == nil)
    }

    @Test("a pasted newline in the name cannot break the line structure")
    func flattensNewlines() {
        #expect(UserProfileText.rewritingName("Kev\nMurphy", in: "Name: Kev.\nnotes") == "Name: Kev Murphy.\nnotes")
    }
}
