#!/bin/zsh
# energy_counter_probe.sh — what this process's RUSAGE_INFO_V6 `ri_energy_nj` can see (#696 Phase 1).
#
# One small Swift program, three 2 s windows: idle (sleep), a one-core CPU burn, and a Metal
# compute burn with the CPU waiting on the GPU. It prints how far each window moved the
# counter. It runs twice: as a plain process, then ad-hoc signed into an App Sandbox. The
# sandboxed run exits 2 before it reads unless the sandbox is on (HOME is the container and a
# write to the real home is refused), and a positive control first proves that check refuses
# an unsandboxed process. A refused read exits 3. No root, no app, no model. About 20 s.
#
#   macos/tools/perf/energy_counter_probe.sh
#
# Reading it: a counter that moves in the CPU window and not in the GPU window sees the CPU
# only. That is the 2026-10-26 result on an M1 Max, and why the app prices tokens with
# coefficients instead of reading itself (docs/ENERGY_MEASUREMENT.md). The sandboxed run
# leaves an empty container at ~/Library/Containers/dev.scratch.m1k3-energy-probe (macOS
# keeps containers closed to shells, so it cannot clean it up).
#
# Signed: Kev + claude-opus-5.5, 2026-10-26, Confidence 0.85 (the probe the doc quotes, run
# twice that night). Prior: none (new file).
# Review: Kev + claude-opus-5.5, 2026-10-26 (pre-push review fold) — the sandbox arm could not fail: it printed the
# evidence and exited 0 either way. Now PROBE_EXPECT_SANDBOX=1 makes it exit 2 unless the sandbox is on (with a
# positive control on the plain binary), a failed proc_pid_rusage exits 3 instead of printing zeroed deltas, and
# codesign's stderr is shown when it fails. Re-run twice afterwards; the doc quotes those runs. Confidence 0.85.

set -euo pipefail

work=$(mktemp -d -t m1k3-energy-probe)
trap 'rm -rf "$work"' EXIT

cat > "$work/probe.swift" <<'SWIFT'
import Darwin
import Foundation
import Metal

func read() -> (energy: UInt64, penergy: UInt64, billed: UInt64, rc: Int32) {
    var info = rusage_info_v6()
    let rc = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0) }
    }
    return (info.ri_energy_nj, info.ri_penergy_nj, info.ri_billed_energy, rc)
}

func fail(_ code: Int32, _ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func window(_ name: String, _ body: () -> Void) {
    let a = read(), t0 = Date()
    body()
    let b = read(), s = Date().timeIntervalSince(t0)
    if a.rc != 0 || b.rc != 0 { fail(3, "\(name): proc_pid_rusage(RUSAGE_INFO_V6) refused (rc \(a.rc), \(b.rc))") }
    let joules = Double(Int64(bitPattern: b.energy &- a.energy)) / 1e9
    let pJoules = Double(Int64(bitPattern: b.penergy &- a.penergy)) / 1e9
    let billed = Int64(bitPattern: b.billed &- a.billed)
    print(String(format: "%-9@ rc=%d %.2f s  energy_nj Δ %.3f J (%.2f W)  P-cores Δ %.3f J  billed Δ %lld",
                 name as NSString, b.rc, s, joules, joules / s, pJoules, billed))
}

let realHome = String(cString: getpwuid(getuid())!.pointee.pw_dir)
let container = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"]
let canary = realHome + "/.m1k3-energy-probe-\(getpid())"
let wroteHome = FileManager.default.createFile(atPath: canary, contents: Data())
if wroteHome { try? FileManager.default.removeItem(atPath: canary) }
print("sandbox: container \(container ?? "none"), HOME=\(NSHomeDirectory()), write to \(realHome) \(wroteHome ? "allowed" : "refused")")
if ProcessInfo.processInfo.environment["PROBE_EXPECT_SANDBOX"] == "1", container == nil || wroteHome {
    fail(2, "sandbox: NOT on (no container, or the real home took a write): no sandboxed reading to report")
}

let source = """
#include <metal_stdlib>
using namespace metal;
kernel void burn(device float *out [[buffer(0)]], uint id [[thread_position_in_grid]]) {
    float x = float(id) * 1e-6f; float y = 1.0f;
    for (uint i = 0; i < 20000; i++) { x = fma(x, 1.000001f, y); y = fma(y, 0.999999f, x * 1e-7f); }
    out[id] = x + y;
}
"""
let device = MTLCreateSystemDefaultDevice()!
let pipeline = try! device.makeComputePipelineState(
    function: device.makeLibrary(source: source, options: nil).makeFunction(name: "burn")!
)
let count = 1 << 20
let buffer = device.makeBuffer(length: count * 4, options: .storageModeShared)!
let queue = device.makeCommandQueue()!
func gpuPass() -> Double {
    let commands = queue.makeCommandBuffer()!, encoder = commands.makeComputeCommandEncoder()!
    encoder.setComputePipelineState(pipeline)
    encoder.setBuffer(buffer, offset: 0, index: 0)
    encoder.dispatchThreads(MTLSize(width: count, height: 1, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
    encoder.endEncoding(); commands.commit(); commands.waitUntilCompleted()
    return commands.gpuEndTime - commands.gpuStartTime
}
_ = gpuPass() // compile and warm before any window opens
print("device: \(device.name)")
window("idle") { Thread.sleep(forTimeInterval: 2) }
window("cpu-burn") {
    let t0 = Date(); var x = 0.0
    while Date().timeIntervalSince(t0) < 2 { x += sin(x) + 1 }
    if x < 0 { print(x) }
}
var gpuBusy = 0.0
window("gpu-burn") { let t0 = Date(); while Date().timeIntervalSince(t0) < 2 { gpuBusy += gpuPass() } }
print(String(format: "the GPU was busy %.2f s of the gpu-burn window", gpuBusy))
SWIFT

cat > "$work/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.scratch.m1k3-energy-probe</string>
<key>CFBundleName</key><string>energy-probe</string>
</dict></plist>
PLIST

cat > "$work/sandbox.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.app-sandbox</key><true/></dict></plist>
PLIST

# A sandboxed command-line tool needs an embedded Info.plist, or it traps at launch (exit 133).
xcrun swiftc -O "$work/probe.swift" -o "$work/probe" \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$work/Info.plist"
print "$(sysctl -n machdep.cpu.brand_string), macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)), $(pmset -g batt | head -1 | sed 's/^Now drawing from //')"

print "== plain process"
"$work/probe"

# The sandbox check's positive control: run unsandboxed, it must refuse with exit 2.
PROBE_EXPECT_SANDBOX=1 "$work/probe" >/dev/null 2>&1 && control=0 || control=$?
if (( control != 2 )); then
  print -u2 "the sandbox check's control exited $control, not 2, so the sandboxed arm proves nothing"
  exit 1
fi

cp "$work/probe" "$work/probe-sandboxed"
codesign -s - -f -i dev.scratch.m1k3-energy-probe --entitlements "$work/sandbox.entitlements" \
  "$work/probe-sandboxed" 2>"$work/codesign.log" || { cat "$work/codesign.log" >&2; exit 1; }
print "== App Sandbox (ad-hoc signed)"
PROBE_EXPECT_SANDBOX=1 "$work/probe-sandboxed"
