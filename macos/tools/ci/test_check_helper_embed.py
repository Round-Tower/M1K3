"""Pins for check_helper_embed's pure helper (the rule the export crash proved)."""
import check_helper_embed as m


def project(copy):
    return {
        "targets": {
            "App": {"type": "application", "dependencies": [{"target": "tool", "embed": True, **copy}]},
            "tool": {"type": "tool"},
            "Saver": {"type": "bundle"},
        }
    }


def test_executables_destination_is_flagged():
    assert m.misplaced_tool_embeds(project({"copy": {"destination": "executables"}})) == [
        "App embeds tool at executables"
    ]


def test_missing_copy_block_is_flagged():
    assert m.misplaced_tool_embeds(project({})) == ["App embeds tool at (no copy block)"]


def test_wrapper_without_helpers_subpath_is_flagged():
    assert m.misplaced_tool_embeds(project({"copy": {"destination": "wrapper", "subpath": "Contents/MacOS"}})) == [
        "App embeds tool at wrapper/Contents/MacOS"
    ]


def test_helpers_subpath_passes():
    assert m.misplaced_tool_embeds(project({"copy": {"destination": "wrapper", "subpath": "Contents/Helpers"}})) == []
    assert m.misplaced_tool_embeds(project({"copy": {"destination": "wrapper", "subpath": "Contents/Helpers/cli"}})) == []


def test_non_tool_embeds_and_unembedded_tools_are_ignored():
    p = project({"copy": {"destination": "executables"}})
    p["targets"]["App"]["dependencies"] = [
        {"target": "Saver", "embed": True, "copy": {"destination": "resources"}},  # a bundle, not a tool
        {"target": "tool", "embed": False},  # linked, not embedded
        {"package": "M1K3", "product": "Core"},  # not a target dep at all
    ]
    assert m.misplaced_tool_embeds(p) == []
