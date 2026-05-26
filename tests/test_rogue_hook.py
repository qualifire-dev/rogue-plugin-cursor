"""
Unit tests for the small pieces of intelligence the dispatcher retains:
  - parsing ~/.rogue-env / /etc/rogue/env
  - the unconfigured-sessionStart hint
  - emitting {} on missing or malformed server response
The full HTTP round-trip is covered by tests/test_smoke.sh.
"""
import importlib.util
import io
import json
import pathlib
import pytest

HOOK_SCRIPT = pathlib.Path(__file__).parent.parent / "plugins" / "rogue" / "scripts" / "rogue-hook.py"


def _load_module():
    spec = importlib.util.spec_from_file_location("rogue_hook", HOOK_SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture(scope="module")
def mod():
    return _load_module()


# ─── credential file parsing ────────────────────────────────────────────

def test_load_creds_parses_export_lines(mod, tmp_path, monkeypatch):
    f = tmp_path / "rogue-env"
    f.write_text(
        "# comment\n"
        "export ROGUE_API_KEY=rsk_abc123\n"
        "export ROGUE_ACTOR_EMAIL='you@example.com'\n"
        'export ROGUE_ACTOR_NAME="Your Name"\n'
    )
    monkeypatch.setattr(mod, "_CRED_FILES", (str(f),))
    monkeypatch.delenv("ROGUE_API_KEY", raising=False)
    monkeypatch.delenv("ROGUE_ACTOR_EMAIL", raising=False)
    monkeypatch.delenv("ROGUE_ACTOR_NAME", raising=False)
    creds = mod._load_creds()
    assert creds["ROGUE_API_KEY"] == "rsk_abc123"
    assert creds["ROGUE_ACTOR_EMAIL"] == "you@example.com"
    assert creds["ROGUE_ACTOR_NAME"] == "Your Name"


def test_load_creds_process_env_overrides_file(mod, tmp_path, monkeypatch):
    f = tmp_path / "rogue-env"
    f.write_text("export ROGUE_API_KEY=from_file\n")
    monkeypatch.setattr(mod, "_CRED_FILES", (str(f),))
    monkeypatch.setenv("ROGUE_API_KEY", "from_env")
    creds = mod._load_creds()
    assert creds["ROGUE_API_KEY"] == "from_env"


def test_load_creds_missing_file_is_silent(mod, monkeypatch):
    monkeypatch.setattr(mod, "_CRED_FILES", ("/nonexistent/path",))
    monkeypatch.delenv("ROGUE_API_KEY", raising=False)
    assert mod._load_creds() == {}


# ─── JSON-validation fail-open ──────────────────────────────────────────

def test_emit_bytes_passes_valid_json_through(mod, capsys):
    mod._emit_bytes(b'{"permission":"ask","user_message":"hi"}')
    assert capsys.readouterr().out == '{"permission":"ask","user_message":"hi"}'


def test_emit_bytes_empty_becomes_empty_object(mod, capsys):
    mod._emit_bytes(b"")
    assert capsys.readouterr().out == "{}"


def test_emit_bytes_malformed_json_fails_open(mod, capsys):
    mod._emit_bytes(b"not valid json at all")
    assert capsys.readouterr().out == "{}"


# ─── unconfigured behavior (no API key) ─────────────────────────────────

def test_unconfigured_session_start_emits_hint(mod, monkeypatch, capsys):
    monkeypatch.setattr(mod, "_load_creds", lambda: {})
    monkeypatch.setattr("sys.stdin", io.StringIO("{}"))
    mod.main(["rogue-hook.py", "sessionStart"])
    out = json.loads(capsys.readouterr().out)
    assert "additional_context" in out
    assert "/rogue:setup" in out["additional_context"]


def test_unconfigured_other_event_emits_empty(mod, monkeypatch, capsys):
    monkeypatch.setattr(mod, "_load_creds", lambda: {})
    monkeypatch.setattr("sys.stdin", io.StringIO("{}"))
    mod.main(["rogue-hook.py", "preToolUse"])
    assert capsys.readouterr().out == "{}"


# ─── argv validation ────────────────────────────────────────────────────

def test_no_event_arg_emits_empty(mod, capsys):
    mod.main(["rogue-hook.py"])
    assert capsys.readouterr().out == "{}"
