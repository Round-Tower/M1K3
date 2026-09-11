//
//  ExecutableLookupTests.swift
//  M1K3CLICoreTests
//
//  Finding the client's own CLI (`claude`) before running it. This lived in
//  the executable target with a `environment:` parameter that DEFAULTED to
//  ProcessInfo — so the one call site quietly bypassed the injected
//  environment the rest of the runner honours. Moved here, the default is
//  gone: you cannot call it without saying whose environment you mean.
//
//  Signed: Kev + claude-opus-5, 2026-09-11, Confidence 0.9 (real files on a
//  real temp PATH, so the executable-bit predicate is exercised too, not
//  faked). Prior: Unknown.
//

import Foundation
@testable import M1K3CLICore
import Testing

struct ExecutableLookupTests {
    private let files = FileManager.default

    /// A real directory with a real file in it — `swift test` here is
    /// UNSANDBOXED, so everything stays under the temp root and is removed.
    private func sandbox() throws -> URL {
        let dir = files.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("m1k3-lookup-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ name: String, in dir: URL, executable: Bool) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try files.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
        return url
    }

    @Test("an executable on the given PATH is found")
    func findsOnPath() throws {
        let dir = try sandbox()
        defer { try? files.removeItem(at: dir) }
        let stub = try write("claude", in: dir, executable: true)
        #expect(ExecutableLookup.locate("claude", environment: ["PATH": dir.path], home: "/Users/nobody") == stub)
    }

    @Test("a file of the right name that isn't executable is not it")
    func ignoresNonExecutable() throws {
        let dir = try sandbox()
        defer { try? files.removeItem(at: dir) }
        _ = try write("claude", in: dir, executable: false)
        #expect(ExecutableLookup.locate("claude", environment: ["PATH": dir.path], home: "/Users/nobody") == nil)
    }

    @Test("~/.local/bin is searched too — a GUI-launched process's PATH usually misses it")
    func searchesLocalBin() throws {
        let home = try sandbox()
        defer { try? files.removeItem(at: home) }
        let bin = home.appendingPathComponent(".local/bin", isDirectory: true)
        try files.createDirectory(at: bin, withIntermediateDirectories: true)
        let stub = try write("claude", in: bin, executable: true)
        #expect(ExecutableLookup.locate("claude", environment: ["PATH": "/nonexistent"], home: home.path) == stub)
    }

    @Test("★ relative and empty PATH entries are skipped — never run a `claude` the cwd supplied")
    func skipsRelativeEntries() throws {
        let dir = try sandbox()
        defer { try? files.removeItem(at: dir) }
        _ = try write("claude", in: dir, executable: true)
        // "" is POSIX shorthand for "."; "." and a bare relative name are the
        // same hazard. None of them may resolve.
        let hostile = ["PATH": ":.:\(dir.lastPathComponent)"]
        #expect(ExecutableLookup.locate("claude", environment: hostile, home: "/Users/nobody") == nil)
    }

    @Test("nothing on the path, nothing back")
    func missing() throws {
        let dir = try sandbox()
        defer { try? files.removeItem(at: dir) }
        #expect(ExecutableLookup.locate("claude", environment: ["PATH": dir.path], home: "/Users/nobody") == nil)
    }
}
