import Foundation
import Testing

/// MLX cannot run under `swift test` (the metallib wall), so the rule is pinned on the source: every read
/// out of MLX in this module goes through `KokoroGuardedRead`, because a bare `asArray` or `item` turns a
/// GPU failure into a `fatalError`. A tester's 1.3.0 crash (app in the background, a sentence still being
/// synthesised) was exactly that. The guard's behaviour is proven by launch (`KokoroLaunchChecks`).
struct KokoroGuardedReadScanTests {
    private static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/M1K3Kokoro")

    private static func swiftFiles() throws -> [URL] {
        let walker = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    @Test("no file but the guard reads values out of MLX")
    func readsGoThroughTheGuard() throws {
        let files = try Self.swiftFiles()
        #expect(files.count > 10, "the scan found the module")
        var bare: [String] = []
        for file in files where file.lastPathComponent != "KokoroGuardedRead.swift" {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let code = line.components(separatedBy: "//").first ?? ""
                if code.contains(".asArray(") || code.contains(".item(") || code.contains(".asData(") {
                    bare.append("\(file.lastPathComponent):\(index + 1)")
                }
            }
        }
        #expect(bare.isEmpty, "bare MLX reads: \(bare)")
    }

    @Test("the guard checks for an MLX error before it touches the bytes")
    func checkComesBeforeTheRead() throws {
        let guardFile = Self.sources.appendingPathComponent("KokoroGuardedRead.swift")
        let source = try String(contentsOf: guardFile, encoding: .utf8)
        let body = try #require(source.range(of: "static func values"))
        let rest = source[body.upperBound...]
        let evaluated = try #require(rest.range(of: "array.eval()"))
        let checked = try #require(rest.range(of: "try failure.check()"))
        let read = try #require(rest.range(of: "array.asArray(type)"))
        #expect(evaluated.lowerBound < checked.lowerBound && checked.lowerBound < read.lowerBound)
    }

    @Test("the synthesiser's forward pass runs inside the error scope")
    func inferIsScoped() throws {
        let source = try String(
            contentsOf: Self.sources.appendingPathComponent("KokoroSynthesizer.swift"), encoding: .utf8
        )
        let infer = try #require(source.range(of: "private static func infer"))
        #expect(source[infer.upperBound...].contains("try KokoroGuardedRead.scope {"))
    }
}
