import os
import subprocess
import sys
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader
from pathlib import Path

# Load mc module from executable file without .py extension
MC_PATH = Path(__file__).parent.parent / "mc"
loader = SourceFileLoader("mc", str(MC_PATH))
spec = spec_from_loader("mc", loader)
mc = module_from_spec(spec)
sys.modules["mc"] = mc
loader.exec_module(mc)


def test_format_error_oserror_with_filename():
    """Verify OSError formatting does not truncate mid-path."""
    err = FileNotFoundError(
        2, "No such file or directory", "/some/deeply/nested/path/to/my_service"
    )
    formatted = mc.format_error(err)
    assert "[Errno 2]" in formatted
    assert "No such file or directory" in formatted
    assert "my_service" in formatted
    assert not formatted.endswith("/to/")


def test_format_error_oserror_without_filename():
    """Verify OSError without filename includes errno and message."""
    err = OSError(111, "Connection refused")
    formatted = mc.format_error(err)
    assert "[Errno 111]" in formatted
    assert "Connection refused" in formatted


def test_format_error_long_string_boundary():
    """Verify long general exceptions truncate at word/separator boundary with ellipsis."""
    msg = "This is a very long error message that contains multiple words and paths like /usr/local/bin/somewhere"
    err = RuntimeError(msg)
    formatted = mc.format_error(err, max_len=40)
    assert len(formatted) <= 45
    assert formatted.endswith("...")
    assert not formatted.endswith("somewh...")


def test_color_degradation_non_tty():
    """Verify colors degrade to plain text when not a TTY or NO_COLOR is set."""
    assert mc.strip_ansi(mc.green("success")) == "success"
    plain = mc._c("test", "32", force_color=False)
    assert plain == "test"


def test_mc_status_empty_home(tmp_path):
    """Verify HOME=/tmp/emptyhome ./mc status runs with zero errors and clean hints."""
    env = os.environ.copy()
    env["HOME"] = str(tmp_path)
    env["NO_COLOR"] = "1"

    proc = subprocess.run(
        [sys.executable, str(MC_PATH), "status"],
        capture_output=True,
        text=True,
        env=env,
        timeout=15,
    )
    assert proc.returncode == 0
    out = proc.stdout

    # Must contain sections
    assert "traces" in out
    assert "LangSmith" in out
    assert "code-factory" in out
    assert "runtime plane" in out
    assert "connectors summary" in out

    # Must contain one-line hints rather than bare cryptic errors
    assert "expected" in out
    assert "trace store found" in out

    # Must NOT contain chopped paths
    assert "code-)" not in out
    assert "mcp-connect)" not in out
    assert ".venv\n" not in out

    # Must include summary line
    assert "SUMMARY" in out or "DEGRADED" in out or "OPERATIONAL" in out


def test_summary_banner_generation():
    """Verify summary banner formatting."""
    banner_ok = mc.format_summary_banner(total=9, ok=9, degraded=0)
    assert "ALL OPERATIONAL" in banner_ok or "9/9" in banner_ok

    banner_degraded = mc.format_summary_banner(total=9, ok=4, degraded=5)
    assert "DEGRADED" in banner_degraded
    assert "4/9" in banner_degraded


def test_plugin_contract_example(capsys):
    """Verify the 10-line plugin example from docs/PLUGIN-CONTRACT.md executes cleanly."""

    def check_my_service() -> bool:
        mc.section("my-service")
        path = os.path.expanduser("~/workspace/my-service/config.json")
        if not os.path.exists(path):
            print(f"  {mc.tag_err('not found')} (expected {path}; configure my-service)")
            return False
        try:
            up = mc.tcp_open("127.0.0.1", 8080)
            print(f"  status: {mc.tag_up('UP') if up else mc.tag_err('DOWN')} | port: 8080")
            return up
        except Exception as e:
            print(f"  {mc.tag_err('ERROR')}: {mc.format_error(e)}")
            return False

    res = check_my_service()
    assert res is False
    captured = capsys.readouterr().out
    assert "my-service" in captured
    assert "not found" in captured
    assert "expected" in captured
