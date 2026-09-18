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


# --- the Info.plist section (the sandboxed helper's launch trap, 2026-09-18) --- #


def tool_project(settings):
    p = project({"copy": {"destination": "wrapper", "subpath": "Contents/Helpers"}})
    p["targets"]["tool"]["settings"] = {"base": settings}
    return p


def test_embedded_tool_without_plist_section_is_flagged():
    # The shipped shape: a bundle id, and nothing that puts it INSIDE the binary.
    assert m.tools_without_embedded_plist(tool_project({"PRODUCT_BUNDLE_IDENTIFIER": "app.example.cli"})) == [
        "tool: CREATE_INFOPLIST_SECTION_IN_BINARY is not YES",
        "tool: no Info.plist to embed (GENERATE_INFOPLIST_FILE: YES or an INFOPLIST_FILE)",
    ]


def test_section_flag_alone_has_nothing_to_embed():
    assert m.tools_without_embedded_plist(tool_project({"CREATE_INFOPLIST_SECTION_IN_BINARY": "YES"})) == [
        "tool: no Info.plist to embed (GENERATE_INFOPLIST_FILE: YES or an INFOPLIST_FILE)"
    ]


def test_generated_or_explicit_plist_with_the_section_passes():
    assert m.tools_without_embedded_plist(
        tool_project({"CREATE_INFOPLIST_SECTION_IN_BINARY": "YES", "GENERATE_INFOPLIST_FILE": "YES"})
    ) == []
    assert m.tools_without_embedded_plist(
        tool_project({"CREATE_INFOPLIST_SECTION_IN_BINARY": True, "INFOPLIST_FILE": "Tool/Info.plist"})
    ) == []  # YAML reads a bare YES as a boolean — both spellings must pass


def test_flat_settings_without_a_base_block_are_read_too():
    p = tool_project({})
    p["targets"]["tool"]["settings"] = {"CREATE_INFOPLIST_SECTION_IN_BINARY": "YES", "GENERATE_INFOPLIST_FILE": "YES"}
    assert m.tools_without_embedded_plist(p) == []


def test_unembedded_tools_are_not_this_guards_business():
    p = tool_project({})
    p["targets"]["App"]["dependencies"] = [{"target": "tool", "embed": False}]
    assert m.tools_without_embedded_plist(p) == []
