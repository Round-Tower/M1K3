# Golden Gate release gate — Mac + iOS

This is the two-day, no-new-feature release sequence. It records evidence for
the exact candidate SHA; a previous green build, simulator pass, or a screenshot
from another commit is not a substitute.

## 1. Freeze the candidate

```sh
git status --short
git rev-parse HEAD
git log -1 --format='%H%n%ad%n%s' --date=iso-strict
```

`git status --short` must be empty before the candidate is tagged or archived.
`release-macos.sh` enforces this for the direct-DMG lane. Do not use its dirty
tree escape hatch for a public artifact.

Record the full SHA, tester, device/OS build, and UTC start time in the release
issue before beginning the next step.

## 2. Mac archive and real-MLX gate

The Xcode Cloud Mac `Release` archive runs `ci_post_xcodebuild.sh`. On an
archive it locates the archived `M1K3.app`, launches it with `M1K3_SELFTEST=1`,
and requires both of these report lines:

```
✓ MLX Qwen3-Embedding embed:
✓ MLX generate:
```

Any `✗` stage, a missing report, or a 15-minute timeout fails the archive before
TestFlight distribution. The only bypass is the explicit, auditable
`M1K3_RELEASE_MLX_SMOKE=0`; it is not permitted for this release.

Once the archive appears in TestFlight Internal, install that exact build on a
physical Golden Gate Mac and complete:

- launch first-run and choose Mini; send an ordinary question and a grounded
  document question;
- enable microphone permission, complete one listen/speak round trip, then
  revoke and restore the permission to verify the recovery copy;
- index and delete a disposable document; create then correct a memory; restart
  and confirm both intended persisted states;
- turn web search on and off, confirming no web route is offered while off;
- install the direct DMG on a clean test account, open it through Gatekeeper,
  run `m1k3 status`, and verify the app and CLI version match the candidate.

## 3. iOS physical-device acceptance

Simulator builds prove compile/link only; they do not prove MLX/Metal, TCC, or
the mobile launch path. Use a registered physical iPhone or iPad on the
supported Golden Gate OS, with its UDID substituted below:

```sh
cd macos
tools/screengrab/capture.sh ios <device-udid>
```

The command must exit zero. Inspect the generated chat, voice, documents,
memories, Brain-at-Home, companion, and privacy plates before accepting the
build; the plate verifier is advisory and intentionally does not replace human
review. Then test the TestFlight build itself on the same device:

- first-run Mini chat and one grounded document answer;
- microphone permission, voice listen/speak, background/foreground recovery;
- Mini-to-Lil switch only on a device meeting the memory floor, or paired-Mac
  Brain-at-Home on a lower-memory device;
- a fresh install and an upgrade install, including existing chat/memory data.

Record video or screenshots, model choice, device model, OS build, and result
for every failure or waiver.

## 4. Candidate quality gate

Before external promotion, run the real app's Mini chat evaluation on the
candidate Mac build, not only the standalone fixture probe:

```sh
M1K3_SELFTEST=1 \
M1K3_SELFTEST_CHATEVAL=1 \
M1K3_SELFTEST_CHATEVAL_BRAINS=mini \
M1K3_SELFTEST_CHATEVAL_LIVE_PATH=1 \
M1K3_SELFTEST_OUT=/tmp/m1k3-golden-gate-chateval.log \
/path/to/M1K3.app/Contents/MacOS/M1K3
```

Attach `/tmp/m1k3-golden-gate-chateval.log` and its JSON companion to the
release issue. Failures are release blockers unless explicitly triaged and
signed off with a scoped waiver.

## 5. Promotion and rollback

Promote only after steps 1–4 have evidence for the same SHA. Start with
TestFlight Internal. If a defect escapes, expire the build in App Store Connect,
disable external promotion, and ship a new candidate; never attempt to silently
replace an already distributed build.
