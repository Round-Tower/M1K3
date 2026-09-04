import M1K3Voice
import Testing

/// The launch-time restore rule for M1K3 Voice: reload the neural voice only when
/// the user chose it before AND its weights are already on disk. Either half alone
/// must NOT restore — one would kick a silent ~354 MB re-download on launch, the
/// other would load a voice the user never picked.
struct VoiceTierRestoreTests {
    @Test("chosen and staged — restore")
    func chosenAndStaged() {
        #expect(VoiceTierRestore.shouldRestore(selected: .m1k3Voice, modelStaged: true))
    }

    @Test("chosen but not staged — never a silent re-download on launch")
    func chosenNotStaged() {
        #expect(!VoiceTierRestore.shouldRestore(selected: .m1k3Voice, modelStaged: false))
    }

    @Test("staged but Built-in chosen — the pick wins, not the files on disk")
    func stagedNotChosen() {
        #expect(!VoiceTierRestore.shouldRestore(selected: .builtin, modelStaged: true))
    }

    @Test("neither — nothing to restore")
    func neither() {
        #expect(!VoiceTierRestore.shouldRestore(selected: .builtin, modelStaged: false))
    }

    @Test("Built-in is the first-run default — the download is the consent")
    func firstRunDefault() {
        #expect(VoiceTierRestore.restoredTier(persisted: nil) == .builtin)
        #expect(VoiceTierRestore.restoredTier(persisted: "m1k3Voice") == .m1k3Voice)
        #expect(VoiceTierRestore.restoredTier(persisted: "builtin") == .builtin)
        #expect(VoiceTierRestore.restoredTier(persisted: "kokoro-9000") == .builtin)
    }
}
