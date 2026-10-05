"""Pins for verify_build.py's pure half: reading the app's MCP initialize and
deciding whether the running build is the one about to be submitted."""
from __future__ import annotations

import json

import verify_build as v

INIT = {"jsonrpc": "2.0", "id": 1, "result": {"serverInfo": {"name": "m1k3"}, "instructions": "M1K3 is the user's private, on-device assistant."}}


def test_initialize_is_read_from_sse_or_plain_json():
    assert v.parse_mcp_body("event: message\ndata: " + json.dumps(INIT) + "\n\n")["serverInfo"]["name"] == "m1k3"
    assert v.parse_mcp_body(json.dumps(INIT))["serverInfo"]["name"] == "m1k3"


def test_the_running_build_must_be_the_one_submitted():
    assert v.problems(installed="453", expected="453", running=True, instructions="M1K3 is …") == []
    assert v.problems(installed="442", expected="453", running=True, instructions="x")
    assert v.problems(installed="453", expected="453", running=False, instructions=None)


def test_a_build_without_mcp_instructions_fails():
    # 442 answered initialize with no instructions; #483 is what 453 adds.
    assert v.problems(installed="453", expected="453", running=True, instructions=None)


def test_a_pass_writes_a_stamp_submit_can_read(tmp_path):
    import submit
    path = v.write_stamp(tmp_path, "453", {"instructions_chars": 900})
    assert json.loads(path.read_text())["build"] == "453"
    assert submit.gate_problems("453", stamp_dir=tmp_path) == []  # the round trip the gate depends on


def test_an_error_reply_is_reported_not_crashed_on():
    try:
        v.parse_mcp_body(json.dumps({"jsonrpc": "2.0", "id": 1, "error": {"code": -32001, "message": "unauthorized"}}))
    except ValueError as exc:
        assert "unauthorized" in str(exc)
    else:
        raise AssertionError("an error reply must raise ValueError")


def test_every_problem_is_reported_at_once():
    assert len(v.problems(installed="442", expected="453", running=False, instructions=None)) == 2
