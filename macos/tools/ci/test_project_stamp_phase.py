"""project.yml guard: the app shells stamp GitCommitSHA before signing."""

from pathlib import Path

import yaml

PROJECT = yaml.safe_load((Path(__file__).resolve().parents[2] / "project.yml").read_text())


def test_app_shells_run_the_stamp_phase_unsandboxed():
    for name in ("M1K3", "M1K3iOS"):
        target = PROJECT["targets"][name]
        # post-BUILD: ProcessInfoPlistFile runs after a post-compile phase and would overwrite the stamp
        phases = target.get("postBuildScripts") or []
        assert not any(p.get("name") == "Stamp GitCommitSHA" for p in target.get("postCompileScripts") or []), name
        stamps = [p for p in phases if p.get("name") == "Stamp GitCommitSHA"]
        assert len(stamps) == 1, name
        script = stamps[0]["script"]
        assert "git_commit_stamp.py" in script and "GitCommitSHA" in script, name
        assert "TARGET_BUILD_DIR" in script and "INFOPLIST_PATH" in script, name
        # a sandboxed phase cannot read .git
        assert target["settings"]["base"]["ENABLE_USER_SCRIPT_SANDBOXING"] in (False, "NO"), name  # YAML 1.1: bare NO parses as False
        assert stamps[0].get("basedOnDependencyAnalysis") is False, name
        # the processed plist as a declared input orders the phase after ProcessInfoPlistFile
        assert stamps[0].get("inputFiles") == ["$(TARGET_BUILD_DIR)/$(INFOPLIST_PATH)"], name
