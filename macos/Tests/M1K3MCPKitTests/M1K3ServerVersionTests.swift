@testable import M1K3MCPKit
import Testing

/// The MCP `serverInfo.version` carries the running app's build, so `verify_build.py` can ask the
/// process itself which build is answering (#491).
struct M1K3ServerVersionTests {
    @Test("the version is the marketing version plus the build, as semver build metadata")
    func carriesTheBuild() {
        #expect(M1K3ServerVersion.string(marketing: "1.4.0", build: "546") == "1.4.0+546")
    }

    @Test("anything that is not a plain version and a plain build number falls back, never a half string")
    func fallsBack() {
        #expect(M1K3ServerVersion.string(marketing: nil, build: nil) == M1K3ServerVersion.fallback)
        #expect(M1K3ServerVersion.string(marketing: "1.4.0", build: nil) == M1K3ServerVersion.fallback)
        #expect(M1K3ServerVersion.string(marketing: "1.4.0", build: "") == M1K3ServerVersion.fallback)
        #expect(M1K3ServerVersion.string(marketing: "1.4.0", build: "$(CURRENT_PROJECT_VERSION)") == M1K3ServerVersion.fallback)
        #expect(M1K3ServerVersion.string(marketing: "", build: "546") == M1K3ServerVersion.fallback)
        #expect(M1K3ServerVersion.string(marketing: "one.four", build: "546") == M1K3ServerVersion.fallback)
    }

    @Test("a process with no app bundle (swift test, the stdio binary) reports the fallback")
    func noBundle() {
        #expect(M1K3ServerVersion.string(info: [:]) == M1K3ServerVersion.fallback)
        #expect(M1K3ServerVersion.string(info: ["CFBundleShortVersionString": "1.4.0", "CFBundleVersion": "546"]) == "1.4.0+546")
    }
}
