//
//  ReadingTypographyTests.swift
//  M1K3AnswerBlocksTests
//
//  Signed: Kev + claude-fable-5.2, 2026-11-12, Confidence 0.8, Prior: none (new file).
//  Context: Kev, 2026-11-12, on a Mac chat screenshot: "the font size particularly on
//  Mac - I think it needs to be bigger, with better kerning, and more padding".

import CoreGraphics
@testable import M1K3AnswerBlocks
import Testing

struct ReadingTypographyTests {
    private let faces: [ReadingTypography.Face] = [.standard, .serif, .dyslexia, .bionic]

    @Test("On the Mac every face reads at 15 pt or more, up from the system's 13")
    func macBodyIsLarger() {
        for face in faces {
            let size = ReadingTypography.resolve(face, on: .mac).bodySize
            #expect((size ?? 0) >= 15, "\(face)")
        }
    }

    @Test("On the Mac lines and letters get air: at least 5 pt between lines, tracking above zero")
    func macHasAir() {
        for face in faces {
            let type = ReadingTypography.resolve(face, on: .mac)
            #expect(type.lineSpacing >= 5, "\(face)")
            #expect(type.tracking > 0, "\(face)")
            #expect(type.paragraphSpacing > type.lineSpacing, "\(face): a paragraph break must read as one")
        }
    }

    @Test("The dyslexia face is the roomiest on both idioms")
    func dyslexiaIsRoomiest() {
        for idiom in [ReadingTypography.Idiom.mac, .touch] {
            let dyslexia = ReadingTypography.resolve(.dyslexia, on: idiom)
            for face in faces where face != .dyslexia {
                let other = ReadingTypography.resolve(face, on: idiom)
                #expect(dyslexia.lineSpacing > other.lineSpacing, "\(idiom) \(face)")
                #expect(dyslexia.tracking > other.tracking, "\(idiom) \(face)")
            }
        }
    }

    @Test("No heading is smaller than the body it sits in, and a higher level is never bigger")
    func headingsNeverShrinkBelowBody() {
        for face in faces {
            let type = ReadingTypography.resolve(face, on: .mac)
            let body = type.bodySize ?? 0
            var previous = CGFloat.greatestFiniteMagnitude
            for level in 1 ... 6 {
                let size = type.headingSize(level: level)
                #expect(size >= body, "\(face) h\(level)")
                #expect(size <= previous, "\(face) h\(level)")
                previous = size
            }
            #expect(type.headingSize(level: 9) >= body, "an unknown level still reads")
        }
    }

    @Test("The Mac bubble's inset grows with the text: more than the old 12 by 8")
    func macInsetIsRoomier() {
        let type = ReadingTypography.resolve(.standard, on: .mac)
        #expect(type.insetHorizontal >= 18)
        #expect(type.insetVertical >= 14)
        #expect(type.insetHorizontal > type.insetVertical)
    }

    @Test("Touch keeps today's values: the system body size (Dynamic Type), 2 pt lines, no tracking")
    func touchIsUnchanged() {
        for face in [ReadingTypography.Face.standard, .serif, .bionic] {
            let type = ReadingTypography.resolve(face, on: .touch)
            #expect(type.bodySize == nil, "\(face): nil means the system's body style")
            #expect(type.lineSpacing == 2)
            #expect(type.tracking == 0)
            #expect(type.paragraphSpacing == 8)
        }
        let dyslexia = ReadingTypography.resolve(.dyslexia, on: .touch)
        #expect(dyslexia.bodySize == 15)
        #expect(dyslexia.lineSpacing == 6)
        #expect(dyslexia.tracking == 0.5)
        #expect(dyslexia.headingSize(level: 1) == 22)
        #expect(dyslexia.headingSize(level: 6) == 13)
    }
}
