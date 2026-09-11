//
//  SandboxProbeTests.swift
//  M1K3CLICoreTests
//
//  Whether this copy of `m1k3` is sandboxed. The env var alone is not enough:
//  launchd injects APP_SANDBOX_CONTAINER_ID, so the App Store helper run from
//  a Terminal — the documented route — is sandboxed and would NOT set it. It
//  would then "wire up" Cursor by writing a file inside its own container that
//  Cursor will never read, and print "wrote …" as if it had worked.
//
//  Signed: Kev + claude-opus-5, 2026-09-11, Confidence 0.85 (the redirected-home
//  signal is how the sandbox actually presents; the live getpwuid read behind
//  it is verify-by-run). Prior: Unknown.
//

@testable import M1K3CLICore
import Testing

struct SandboxProbeTests {
    @Test("an unsandboxed process sees its own home")
    func notSandboxed() {
        #expect(!SandboxProbe.isSandboxed(home: "/Users/kev", realHome: "/Users/kev", environment: [:]))
    }

    @Test("★ a redirected home is the sandbox, even with no env var to say so")
    func redirectedHome() {
        #expect(SandboxProbe.isSandboxed(
            home: "/Users/kev/Library/Containers/app.m1k3.cli/Data",
            realHome: "/Users/kev",
            environment: [:]
        ))
    }

    @Test("launchd's env var still counts, for the case where the homes happen to match")
    func environmentVariable() {
        #expect(SandboxProbe.isSandboxed(
            home: "/Users/kev", realHome: "/Users/kev",
            environment: ["APP_SANDBOX_CONTAINER_ID": "app.m1k3.cli"]
        ))
    }

    @Test("an unknown real home is not evidence of anything — don't cry sandbox on a nil")
    func unknownRealHome() {
        #expect(!SandboxProbe.isSandboxed(home: "/Users/kev", realHome: nil, environment: [:]))
    }
}
