#!/usr/bin/env python3
"""Mission control: one-pane status for the agent-stack runtime.

Usage:
    mc status        show traces + LangSmith + agent libs + code-factory +
                     runtime plane + connectors summary + nemotron stub
    mc traces [N]    show last N trace events (default 5)
    mc eval          stack self-test suite (7 tests; exits 1 on failure)
    mc heal          check the 8 toolsets, restart local services that are down
    mc runs [N]      last N mc-invocation run rows (wall-time) from the log
    mc costs [N]     estimated cost rows (model, tokens, USD) — all ESTIMATES
"""

import json
import os
import re
import socket
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
TRACES = os.path.join(HOME, "workspace/org/traces/events.jsonl")
LANGSMITH_CLI = os.path.join(HOME, "workspace/skills/langsmith/bin/langsmith-cli")
VENV_PY = os.path.join(HOME, "workspace/agent-stack/.venv/bin/python")
AGENT_STACK = os.path.join(HOME, "workspace/agent-stack")
CHECK_CLAUDE = os.path.join(AGENT_STACK, "health/check_claude_codex_sdk.py")
CHECK_NVIDIA = os.path.join(AGENT_STACK, "health/check_nvidia_nemotron.py")

# ---------------------------------------------------------------------------
# ANSI Color & Formatting Helpers (stdlib-only, gracefully degrades)
# ---------------------------------------------------------------------------

ANSI_RE = re.compile(r"\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])")


def strip_ansi(text: str) -> str:
    """Strip ANSI escape sequences from string."""
    return ANSI_RE.sub("", str(text))


def should_use_color() -> bool:
    """Return True if terminal supports ANSI color and color is not disabled."""
    if "NO_COLOR" in os.environ:
        return False
    if os.environ.get("CLICOLOR_FORCE", "0") != "0" or os.environ.get("FORCE_COLOR", "0") != "0":
        return True
    if os.environ.get("TERM") == "dumb":
        return False
    return sys.stdout.isatty()


def _c(text, code, force_color=None):
    use = should_use_color() if force_color is None else force_color
    return f"\033[{code}m{text}\033[0m" if use else str(text)


def bold(text):
    return _c(text, "1")


def dim(text):
    return _c(text, "2")


def green(text):
    return _c(text, "32")


def yellow(text):
    return _c(text, "33")


def red(text):
    return _c(text, "31")


def cyan(text):
    return _c(text, "36")


def magenta(text):
    return _c(text, "35")


def tag_ok(text="OK"):
    return _c(f"[{text}]", "1;32")


def tag_up(text="UP"):
    return _c(f"[{text}]", "1;32")


def tag_warn(text="DEGRADED"):
    return _c(f"[{text}]", "1;33")


def tag_err(text="ERROR"):
    return _c(f"[{text}]", "1;31")


def tag_info(text="INFO"):
    return _c(f"[{text}]", "36")


def format_error(exc, max_len=80):
    """Format an exception for single-line display without mid-path truncation."""
    if isinstance(exc, OSError):
        err = exc.strerror or str(exc)
        code_prefix = f"[Errno {exc.errno}] " if exc.errno else ""
        if getattr(exc, "filename", None):
            fn = str(exc.filename).rstrip(os.sep)
            base = os.path.basename(fn) or fn
            parent = os.path.basename(os.path.dirname(fn))
            target = f"{parent}/{base}" if parent and parent != "/" else base
            msg = f"{code_prefix}{err}: {target}"
            if len(msg) <= max_len:
                return msg
            msg_base = f"{code_prefix}{err}: {base}"
            if len(msg_base) <= max_len:
                return msg_base
            return msg_base[:max_len]
        msg = f"{code_prefix}{err}"
        return msg if len(msg) <= max_len else msg[:max_len]

    s = str(exc).strip().replace("\n", " ")
    if len(s) <= max_len:
        return s
    truncated = s[:max_len]
    last_sep = max(
        truncated.rfind(" "),
        truncated.rfind("/"),
        truncated.rfind(":"),
        truncated.rfind(","),
    )
    if last_sep > max_len // 2:
        return truncated[:last_sep].rstrip() + "..."
    return truncated.rstrip() + "..."


def format_summary_banner(total: int, ok: int, degraded: int) -> str:
    """Generate across-the-room readable summary banner."""
    width = 72
    line_char = "━" if should_use_color() else "="
    border = line_char * width
    if degraded == 0 and ok == total:
        status_text = f"● ALL OPERATIONAL: {ok}/{total} sections healthy"
        colored_status = bold(green(status_text))
    else:
        status_text = f"▲ DEGRADED: {ok}/{total} healthy ({degraded} missing/degraded)"
        colored_status = bold(yellow(status_text))

    if should_use_color():
        return f"\n{bold(border)}\n  {colored_status}\n{bold(border)}"
    else:
        return f"\n{border}\n  {status_text}\n{border}"


def section(title):
    if should_use_color():
        bar_len = max(4, 70 - len(title) - 4)
        print(f"\n{bold(cyan('━━━ ' + title + ' ' + '━' * bar_len))}")
    else:
        print(f"\n== {title} ==")


# ---------------------------------------------------------------------------
# Section Checks (Never-Raise Plugin Contract)
# ---------------------------------------------------------------------------


def traces_summary(n=5) -> bool:
    section("traces (local JSONL store)")
    if not os.path.exists(TRACES):
        print(f"  no trace store found (expected {TRACES}; emit traces via agent runs)")
        return False
    try:
        st = os.stat(TRACES)
        lines = 0
        last = []
        with open(TRACES) as f:
            for line in f:
                lines += 1
                if len(last) >= n:
                    last.pop(0)
                last.append(line)
        age_h = (time.time() - st.st_mtime) / 3600
        print(f"  file: {TRACES}")
        print(f"  events: {lines} | size: {st.st_size // 1024}KB | last write: {age_h:.1f}h ago")
        for line in last:
            try:
                e = json.loads(line)
                print(f"  - {e.get('ts', '?')} [{e.get('agent', '?')}/{e.get('kind', '?')}]")
            except Exception:
                print("  - <unparseable line>")
        return True
    except Exception as ex:
        print(f"  {tag_err('ERROR')}: {format_error(ex)}")
        return False


def langsmith_status() -> bool:
    section("LangSmith (cloud traces + local auth proxy)")
    if not os.path.exists(LANGSMITH_CLI):
        print(
            f"  langsmith skill CLI not installed (expected {LANGSMITH_CLI}; install via skills/langsmith)"
        )
        return False
    try:
        out = subprocess.run(
            [LANGSMITH_CLI, "check"],
            capture_output=True,
            text=True,
            timeout=60,
        )
        try:
            data = json.loads(out.stdout.strip().splitlines()[-1])
        except Exception:
            data = {}
        if data.get("ok"):
            print(f"  {tag_ok('OK')} via {data.get('host')} | workspaces: {data.get('workspaces')}")
            return True
        else:
            print(
                f"  {tag_warn('UNREACHABLE')} (status={data.get('status')}, host={data.get('host')})"
            )
            print("  -> key likely invalid; reconnect custom.langsmith with a fresh key")
            return False
    except subprocess.TimeoutExpired:
        print(f"  {tag_err('TIMEOUT')} reaching LangSmith")
        return False
    except Exception as e:
        print(f"  {tag_err('ERROR')}: {format_error(e)}")
        return False


def tcp_open(host, port, timeout=2):
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def runtime_status() -> bool:
    section("runtime plane")
    # docker
    docker = False
    docker_bins = [
        "docker",
        os.path.join(HOME, "workspace/bin/docker/docker"),
    ]
    for db in docker_bins:
        try:
            r = subprocess.run([db, "info"], capture_output=True, text=True, timeout=15)
            if r.returncode == 0:
                docker = True
                break
        except Exception:
            continue
    docker_str = (
        tag_up("UP")
        if docker
        else f"{tag_warn('not available')} (start Docker/OrbStack or install docker CLI)"
    )
    print(f"  docker: {docker_str}")

    # redis
    redis_up = tcp_open("127.0.0.1", 6379)
    redis_str = (
        tag_up("UP") if redis_up else f"{tag_warn('down')} (start with 'mc heal' or redis-server)"
    )
    print(f"  redis 127.0.0.1:6379: {redis_str}")

    # agent processes
    count = 0
    try:
        r = subprocess.run(["ps", "-eo", "comm"], capture_output=True, text=True, timeout=10)
        for line in r.stdout.splitlines():
            c = line.strip().lower()
            if c in ("python", "python3", "uvicorn", "node"):
                count += 1
    except Exception:
        pass
    print(f"  agent-ish processes (python/uvicorn/node): {count}")

    # venv sanity
    venv_ok = os.path.exists(VENV_PY)
    venv_str = (
        tag_up("present")
        if venv_ok
        else f"{tag_err('MISSING')} (expected {VENV_PY}; create with python3 -m venv)"
    )
    print(f"  agent-stack venv: {venv_str}")
    if venv_ok:
        try:
            r = subprocess.run(
                [
                    VENV_PY,
                    "-c",
                    "import langgraph, langsmith; print('stack-imports-ok')",
                ],
                capture_output=True,
                text=True,
                timeout=60,
            )
            imports_ok = "stack-imports-ok" in r.stdout
            print(f"  venv imports: {tag_ok('ok') if imports_ok else tag_err('BROKEN')}")
        except Exception as e:
            print(f"  venv imports: {tag_err('ERROR')} {format_error(e)}")

    return venv_ok and redis_up


def code_factory_status() -> bool:
    """Code factory: local code-execution plane health (2026-09-25).

    Fast smoke only: list backends, then run a 5s python hello-world through
    the factory itself. Never raises: any failure reports DEGRADED so
    `mc status` always completes.
    """
    section("code-factory")
    factory_cli = os.path.join(AGENT_STACK, "code-factory", "factory")
    if not os.path.exists(factory_cli):
        print(
            f"  {tag_warn('DEGRADED')}: factory CLI not found (expected {factory_cli}; install code-factory)"
        )
        return False
    try:
        r = subprocess.run(
            [factory_cli, "backends"],
            capture_output=True,
            text=True,
            timeout=30,
        )
        ok = [ln.split(":")[0] for ln in r.stdout.splitlines() if ": available" in ln]
        verdict = (
            "ok"
            if (r.returncode == 0 and ("venv-subprocess" in ok or "plain-subprocess" in ok))
            else "DEGRADED"
        )
        smoke = ""
        try:
            s = subprocess.run(
                [
                    factory_cli,
                    "run",
                    "--language",
                    "python",
                    "--timeout",
                    "5",
                    "--json",
                    "-",
                ],
                input='print("factory-smoke-ok")',
                capture_output=True,
                text=True,
                timeout=30,
            )
            data = json.loads(s.stdout)
            if data.get("stdout", "").strip() == "factory-smoke-ok":
                smoke = f" | hello-world: ok via {data.get('backend_used')}"
            else:
                verdict, smoke = "DEGRADED", " | hello-world: unexpected output"
        except Exception:
            verdict, smoke = "DEGRADED", " | hello-world: failed"
        verdict_tag = tag_ok("ok") if verdict == "ok" else tag_warn("DEGRADED")
        print(f"  {verdict_tag}: backends available: {', '.join(ok) or 'none'}{smoke}")
        return verdict == "ok"
    except Exception as ex:
        print(f"  {tag_warn('DEGRADED')}: factory health check failed ({format_error(ex)})")
        return False


def connectors_summary() -> bool:
    """Connectors summary (2026-09-25): counts from the verified inventory.

    Read-only: parses ~/workspace/vault/mcp-connectors.md (verified
    2026-09-25) plus counts workspace SKILL.md files. No network probes,
    no credentials touched. Never raises: any failure reports DEGRADED
    so `mc status` always completes.
    """
    section("connectors summary")
    inv = os.path.join(HOME, "workspace/vault/mcp-connectors.md")
    if not os.path.exists(inv):
        print(
            f"  {tag_warn('DEGRADED')}: connector inventory not found (expected {inv}; create inventory file)"
        )
        return False
    try:
        # rows: [verified, blocked, nodata, untested] for each of 2 tables
        stats = {"connectors": [0, 0, 0, 0], "platform": [0, 0, 0, 0]}
        table = None
        with open(inv) as f:
            for line in f:
                s = line.strip()
                if s.startswith("| Connector |"):
                    table = "connectors"
                    continue
                if s.startswith("| Skill |"):
                    table = "platform"
                    continue
                if not table or not s.startswith("|") or "---" in s:
                    continue
                if "blocked" in s or "❌" in s:
                    stats[table][1] += 1
                elif "no data" in s:
                    stats[table][2] += 1
                elif "untested" in s:
                    stats[table][3] += 1
                elif "✅" in s:
                    stats[table][0] += 1
        c = stats["connectors"]
        p = stats["platform"]
        total = sum(c)
        if total == 0:
            print(f"  {tag_warn('DEGRADED')}: no connector rows parsed from inventory")
            return False
        print(
            f"  connectors: {c[0]} verified-working / {c[1]} blocked-on-gate / "
            f"{c[2]} plumbing-up-no-data (of {total})"
        )
        if sum(p):
            print(
                f"  platform/local skills: {p[0]} functional / {p[3]} "
                f"configured-untested (of {sum(p)})"
            )
        print(f"  inventory: {inv} (last verified 2026-09-25)")
        try:
            skills_dir = os.path.join(HOME, "workspace/skills")
            n_skills = sum(
                1
                for d in os.listdir(skills_dir)
                if os.path.isfile(os.path.join(skills_dir, d, "SKILL.md"))
            )
            print(f"  workspace skills with SKILL.md: {n_skills}")
        except OSError:
            pass
        return True
    except Exception as ex:
        print(f"  {tag_warn('DEGRADED')}: connectors summary failed ({format_error(ex)})")
        return False


def tailscale_status() -> bool:
    """Device-snapshot freshness from the tailscale-daily-snapshot cron (2026-09-25).

    Read-only: parses the freshness marker JSON; never hits the network.
    """
    section("tailscale device snapshot")
    marker = os.path.join(
        HOME,
        "workspace/goals/empire-ai-100m-ai-agency/hidden_files/tailscale-snapshot-freshness.json",
    )
    if not os.path.exists(marker):
        print(f"  no freshness marker yet (expected {marker}; tailscale snapshot cron pending)")
        return False
    try:
        with open(marker) as f:
            m = json.load(f)
        age_h = (time.time() - os.stat(marker).st_mtime) / 3600
        new = m.get("new") or []
        removed = m.get("removed") or []
        drift = ""
        if new:
            drift += f" NEW={','.join(new)}"
        if removed:
            drift += f" REMOVED={','.join(removed)}"
        print(
            f"  snapshot: {m.get('ts', '?')} ({age_h:.1f}h ago) | "
            f"devices={m.get('device_count', '?')} | "
            f"control-plane={m.get('control_plane', '?')}{drift or ' | no drift'}"
        )
        return True
    except Exception as e:
        print(f"  freshness marker unreadable: {format_error(e)}")
        return False


def nvidia_status() -> bool:
    """NVIDIA Nemotron API connection (ready-to-enable workstream).

    Read-only: runs the local-state health stub (no network, no credentials).
    Reports one of: awaiting-terms-acceptance | awaiting-secure-intake |
    ready-to-enable | enabled.
    """
    section("nvidia-nemotron (API connection)")
    if not os.path.exists(CHECK_NVIDIA):
        print(
            f"  health stub not installed (expected {CHECK_NVIDIA}; configure nvidia check script)"
        )
        return False
    try:
        r = subprocess.run(
            [VENV_PY, CHECK_NVIDIA],
            capture_output=True,
            text=True,
            timeout=30,
        )
        data = json.loads(r.stdout)
        status = data.get("status", "?")
        print(f"  status: {status}")
        print(
            f"  terms: {'accepted' if data.get('terms_accepted') else 'NOT accepted'} | "
            f"key-in-vault: {'yes' if data.get('key_in_vault') else 'no'} | "
            f"live model list: {'refreshed' if data.get('models_refreshed_from_live') else 'not refreshed'}"
        )
        print(f"  candidate models configured: {data.get('candidate_models')}")
        print(f"  next: {data.get('next_action')}")
        return status in ("ready-to-enable", "enabled")
    except Exception as ex:
        print(f"  stub: {tag_err('ERROR')} {format_error(ex)}")
        return False


def agent_stack_status() -> bool:
    """Per-component health for the 9-piece agent fleet (2026-09-25 orchestration).

    Fast, read-only, best-effort: import checks + key-presence only, no values,
    no model calls, no trace spam (full smokes run on the weekly cron).
    """
    section("agent-stack fleet (9 components)")
    if not os.path.exists(VENV_PY):
        print(
            f"  claude/codex/sdk: {tag_err('SKIPPED')} (expected {VENV_PY}; set up agent-stack venv)"
        )
        print(
            f"  framework imports: {tag_err('SKIPPED')} (expected {VENV_PY}; set up agent-stack venv)"
        )
        print(
            f"  agy (Antigravity CLI): {dim('studio-side, unverified — pending Mac Studio access')}"
        )
        print(
            f"  openshell (NVIDIA OpenShell): {dim('studio-side, unverified — pending Mac Studio access')}"
        )
        print(
            f"  heartbeats: {dim('agent-stack-health (weekly) | claude-codex-sdk-health (daily)')}"
        )
        return False

    all_ok = True
    # 1-3: claude / codex / sdk via the leaf-built health script (no network, no traces)
    try:
        r = subprocess.run(
            [VENV_PY, CHECK_CLAUDE],
            capture_output=True,
            text=True,
            timeout=60,
        )
        data = json.loads(r.stdout)
        for comp in ("claude", "codex", "sdk"):
            e = data["components"][comp]
            imps = e.get("imports", {})
            imp_ok = all(v.get("ok") for v in imps.values()) if imps else True
            if not imp_ok:
                all_ok = False
            key = "key?" if e.get("key_present_in_process_env") else "no-key"
            extra = ""
            if comp == "codex":
                extra = f" cli={e.get('cli_version') or 'missing'} auth={e.get('auth_verdict')}"
            elif "live" in e:
                extra = f" live={e['live'].get('status')}"
            imp_tag = tag_ok("ok") if imp_ok else tag_err("BROKEN")
            print(f"  {comp:6s} imports={imp_tag} {key}{extra}")
    except Exception as ex:
        all_ok = False
        print(f"  claude/codex/sdk script: {tag_err('ERROR')} {format_error(ex)}")

    # 4-6: adk / langchain-langgraph / deepagents — import-only (fast, no traces)
    try:
        r = subprocess.run(
            [
                VENV_PY,
                "-c",
                "import google.adk, langchain, langgraph, deepagents;"
                " print('adk,langchain,langgraph,deepagents imports ok')",
            ],
            capture_output=True,
            text=True,
            timeout=90,
        )
        ok = "imports ok" in r.stdout
        if not ok:
            all_ok = False
        print(
            f"  adk/langchain/langgraph/deepagents imports: {tag_ok('ok') if ok else tag_err('BROKEN')}"
        )
        if not ok and r.stderr:
            first_err = (r.stderr.strip().splitlines() or [""])[0]
            print(f"    {format_error(first_err, max_len=100)}")
    except Exception as ex:
        all_ok = False
        print(f"  framework imports: {tag_err('ERROR')} {format_error(ex)}")

    # 7: langsmith covered by its own section above; 8-9: studio-side CLIs
    print(f"  agy (Antigravity CLI): {dim('studio-side, unverified — pending Mac Studio access')}")
    print(
        f"  openshell (NVIDIA OpenShell): {dim('studio-side, unverified — pending Mac Studio access')}"
    )
    print(f"  heartbeats: {dim('agent-stack-health (weekly) | claude-codex-sdk-health (daily)')}")
    return all_ok


def gstack_adopted_status() -> bool:
    """Garry Tan (gstack, MIT) adoptions — harness presence + guardian self-test.

    Read-only, best-effort, never raises: any failure reports DEGRADED so
    `mc status` always completes. Added 2026-09-25.
    """
    section("gstack-adopted harnesses (garrytan/gstack, MIT)")
    base = os.path.join(AGENT_STACK, "gstack-adopted")
    if not os.path.exists(base):
        print(
            f"  {tag_warn('DEGRADED')}: gstack directory not found (expected {base}; clone garrytan/gstack)"
        )
        return False
    try:
        prompts_dir = os.path.join(base, "prompts")
        n_prompts = (
            sum(1 for f in os.listdir(prompts_dir) if f.endswith(".md"))
            if os.path.isdir(prompts_dir)
            else 0
        )
        guardian = os.path.join(base, "guardian.py")
        slop = os.path.join(base, "slop-scan.py")
        have = [p for p in (guardian, slop) if os.path.isfile(p)]
        # guardian self-test: clean -> 0, 'rm -rf /' -> 2
        selftest = "?"
        if os.path.isfile(guardian):
            try:
                c = subprocess.run(
                    [sys.executable, guardian, "--cmd", "echo ok"],
                    capture_output=True,
                    text=True,
                    timeout=15,
                )
                d = subprocess.run(
                    [sys.executable, guardian, "--cmd", "rm -rf /"],
                    capture_output=True,
                    text=True,
                    timeout=15,
                )
                selftest = "ok" if (c.returncode == 0 and d.returncode == 2) else "FAILED"
            except Exception:
                selftest = "ERROR"
        verdict = "ok" if (n_prompts >= 10 and len(have) == 2 and selftest == "ok") else "DEGRADED"
        verdict_tag = tag_ok("ok") if verdict == "ok" else tag_warn("DEGRADED")
        print(
            f"  {verdict_tag}: prompts={n_prompts} "
            f"executables={len(have)}/2 guardian-selftest={selftest}"
        )
        return verdict == "ok"
    except Exception as ex:
        print(f"  {tag_warn('DEGRADED')}: gstack-adopted check failed ({format_error(ex)})")
        return False


# ---------------------------------------------------------------------------
# Ceiling Program, Pillar 2 (2026-09-25): self-test, self-healing, run/cost
# logging. Additive only: nothing above this line is modified, and
# `mc status` / `mc traces` / code-factory behavior are unchanged.
# Stdlib only; `mc` never raises from these paths either.
# ---------------------------------------------------------------------------

HEALTH_DIR = os.path.join(AGENT_STACK, "health")
RUNS_LOG = os.path.join(HEALTH_DIR, "runs.jsonl")
EVAL_LOG = os.path.join(HEALTH_DIR, "eval-history.jsonl")
CRON_DIR = os.path.join(HOME, "workspace/cron.d")
BIN_DIR = os.path.join(HOME, "workspace/bin")
VAULT_INDEX = os.path.join(HOME, "workspace/vault/index.md")
CONNECTORS_INV = os.path.join(HOME, "workspace/vault/mcp-connectors.md")
FACTORY_CLI = os.path.join(AGENT_STACK, "code-factory", "factory")
E2E_TRACE = os.path.join(AGENT_STACK, "e2e_deepagents_trace.py")

# Cost estimates only. USD per 1M input/output tokens. Every figure derived
# from this table is presented as an ESTIMATE, never a billed amount.
EST_PRICES = {
    "e2e-stub": (0.0, 0.0),  # self-test stub: no LLM call is made
}


def _append_jsonl(path, row):
    """Best-effort JSONL append. Logging must never break the command."""
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "a") as f:
            f.write(json.dumps(row) + "\n")
    except OSError:
        pass


def est_cost_usd(model, in_tok, out_tok):
    if not model or model not in EST_PRICES:
        return None, None
    pi, po = EST_PRICES[model]
    in_tok = in_tok or 0
    out_tok = out_tok or 0
    return in_tok / 1e6 * pi + out_tok / 1e6 * po, "ESTIMATE"


def log_run(argv, wall_ms, model=None, est_in=None, est_out=None):
    usd, label = est_cost_usd(model, est_in, est_out)
    _append_jsonl(
        RUNS_LOG,
        {
            "ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
            "argv": list(argv),
            "wall_ms": round(wall_ms, 1),
            "model": model,
            "est_in_tokens": est_in,
            "est_out_tokens": est_out,
            "est_usd": usd,
            "cost_label": label,
        },
    )


# ---- mc eval ---------------------------------------------------------------


def _eval_timed(fn):
    t0 = time.time()
    try:
        ok, note, cost = fn()
    except Exception as e:  # noqa: BLE001 - a failing test reports, not raises
        ok, note, cost = False, f"exception: {format_error(e)}", None
    return {
        "ok": bool(ok),
        "ms": round((time.time() - t0) * 1000, 1),
        "note": note or "",
        "cost": cost,
    }


def _t_factory_hello():
    r = subprocess.run(
        [
            FACTORY_CLI,
            "run",
            "--language",
            "python",
            "--timeout",
            "10",
            "--json",
            "-",
        ],
        input='print("eval-hello-ok")',
        capture_output=True,
        text=True,
        timeout=30,
    )
    try:
        data = json.loads(r.stdout)
    except Exception:
        return False, f"factory run unparsable (rc={r.returncode})", None
    ok = data.get("stdout", "").strip() == "eval-hello-ok"
    return ok, f"backend={data.get('backend_used')}", None


def _t_factory_backends():
    r = subprocess.run(
        [FACTORY_CLI, "backends"],
        capture_output=True,
        text=True,
        timeout=30,
    )
    ok = [ln.split(":")[0] for ln in r.stdout.splitlines() if ": available" in ln]
    good = r.returncode == 0 and ("venv-subprocess" in ok or "plain-subprocess" in ok)
    return good, f"available={','.join(ok) or 'none'}", None


def _t_proxy_health():
    r = subprocess.run(
        [
            "curl",
            "-sf",
            "--max-time",
            "8",
            "http://127.0.0.1:17888/api/v1/info",
        ],
        capture_output=True,
        text=True,
        timeout=20,
    )
    return (
        r.returncode == 0,
        ("proxy /api/v1/info reachable" if r.returncode == 0 else "proxy unreachable"),
        None,
    )


def _t_trace_roundtrip():
    r = subprocess.run([VENV_PY, E2E_TRACE], capture_output=True, text=True, timeout=150)
    ok = "E2E invoke completed" in r.stdout
    note = (
        "trace round-trip ok"
        if ok
        else format_error((r.stderr.strip().splitlines() or ["e2e trace failed"])[0])
    )
    cost = {
        "model": "e2e-stub",
        "est_in_tokens": 0,
        "est_out_tokens": 0,
        "est_usd": 0.0,
        "label": "ESTIMATE",
    }
    return ok, note, cost


def _t_connector_inventory():
    rows = 0
    try:
        with open(CONNECTORS_INV) as f:
            for line in f:
                s = line.strip()
                if (
                    s.startswith("|")
                    and "---" not in s
                    and not s.startswith("| Connector |")
                    and not s.startswith("| Skill |")
                ):
                    rows += 1
    except OSError as e:
        return False, f"inventory unreadable: {format_error(e)}", None
    return rows >= 10, f"{rows} inventory rows parsed", None


def _t_vault_lookup():
    try:
        with open(VAULT_INDEX) as f:
            text = f.read()
    except OSError as e:
        return False, f"vault index unreadable: {format_error(e)}", None
    ok = "status-dashboard" in text
    return (
        ok,
        ("index lookup hit: status-dashboard" if ok else "status-dashboard not found in index"),
        None,
    )


def _t_cron_inventory():
    jobs = []
    try:
        for sub in (
            "minutely",
            "hourly",
            "daily",
            "weekly",
            "monthly",
            "yearly",
            "runonce",
            "secondly",
        ):
            d = os.path.join(CRON_DIR, sub)
            if not os.path.isdir(d):
                continue
            for fn in os.listdir(d):
                if fn.endswith(".md"):
                    jobs.append(fn)
    except OSError as e:
        return False, f"cron.d unreadable: {format_error(e)}", None
    have_watchdog = any("local-infra-watchdog" in j for j in jobs)
    ok = len(jobs) >= 3 and have_watchdog
    return (
        ok,
        f"{len(jobs)} active job defs; watchdog={'yes' if have_watchdog else 'no'}",
        None,
    )


EVAL_TESTS = [
    ("factory-python-hello", _t_factory_hello),
    ("factory-backends", _t_factory_backends),
    ("langsmith-proxy-health", _t_proxy_health),
    ("langsmith-trace-roundtrip", _t_trace_roundtrip),
    ("connector-inventory-sanity", _t_connector_inventory),
    ("vault-lookup", _t_vault_lookup),
    ("cron-inventory-sanity", _t_cron_inventory),
]


def cmd_eval():
    """Run the stack self-test suite. Returns True iff every test passes."""
    print("mc eval :: agent-stack self-test suite")
    results = []
    for name, fn in EVAL_TESTS:
        res = _eval_timed(fn)
        res["name"] = name
        results.append(res)
        flag = tag_ok("PASS") if res["ok"] else tag_err("FAIL")
        print(f"  {flag} {name} ({res['ms']}ms) {res['note']}")
    passed = sum(1 for r in results if r["ok"])
    _append_jsonl(
        EVAL_LOG,
        {
            "ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
            "passed": passed,
            "total": len(results),
            "tests": results,
        },
    )
    print(f"  -> {passed}/{len(results)} passed | history: {EVAL_LOG}")
    return passed == len(results)


# ---- mc heal ---------------------------------------------------------------

START_SCRIPTS = {
    "langsmith-proxy": ("start-langsmith-proxy.sh", "127.0.0.1", 17888),
    "redis": ("start-redis.sh", "127.0.0.1", 6379),
    "docker": ("start-docker.sh", None, None),
}


def _docker_up():
    try:
        r = subprocess.run(
            [os.path.join(BIN_DIR, "docker", "docker"), "info"],
            capture_output=True,
            text=True,
            timeout=20,
        )
        return r.returncode == 0
    except Exception:
        return False


def _restart_local(name):
    """Restart a local service via its start script. Never touches remotes."""
    script = os.path.join(BIN_DIR, START_SCRIPTS[name][0])
    try:
        r = subprocess.run(
            ["bash", script],
            capture_output=True,
            text=True,
            timeout=120,
        )
        tail = (r.stdout.strip().splitlines() or [""])[-1][:120]
        return r.returncode == 0, tail
    except Exception as e:  # noqa: BLE001
        return False, f"restart exception: {format_error(e)}"


def cmd_heal():
    """Check the 8 toolsets; restart downed LOCAL services via start-*.sh.

    Only local processes are ever restarted. Remote systems (LangSmith
    cloud, Mac Studio, connectors, cron schedules) are report-only.
    Returns True iff nothing is left degraded.
    """
    print("mc heal :: check 8 toolsets, restart what is locally restartable")
    degraded = 0

    # 1-3: local services with a real restart path
    restartable = [
        ("langsmith-proxy", lambda: tcp_open("127.0.0.1", 17888)),
        ("redis", lambda: tcp_open("127.0.0.1", 6379)),
        ("docker", _docker_up),
    ]
    for name, probe in restartable:
        try:
            up = probe()
        except Exception:
            up = False
        if up:
            print(f"  {tag_up('UP'):12s} {name}")
            continue
        print(f"  {tag_err('DOWN'):12s} {name} -> restarting via {START_SCRIPTS[name][0]}")
        ok, note = _restart_local(name)
        try:
            up_after = probe()
        except Exception:
            up_after = False
        if ok and up_after:
            print(f"  {tag_ok('RESTARTED'):12s} {name} ({note})")
        else:
            degraded += 1
            print(f"  {tag_err('STILL-DOWN'):12s} {name} ({note})")

    # 4-8: report-only (no safe local restart exists)
    ro_checks = [
        (
            "agent-venv",
            lambda: os.path.exists(VENV_PY),
            "no restart path: reinstall venv manually",
        ),
        (
            "code-factory",
            lambda: os.path.isfile(FACTORY_CLI),
            "subprocess fallback covers docker-sandbox loss",
        ),
        (
            "connector-inventory",
            lambda: os.path.isfile(CONNECTORS_INV),
            "inventory is a file; refresh is a worker job",
        ),
        (
            "cron-definitions",
            lambda: os.path.isdir(CRON_DIR),
            "schedules live in the runtime, not here",
        ),
        (
            "trace-store",
            lambda: os.path.isdir(os.path.dirname(TRACES)),
            "missing dir would need manual recreation",
        ),
    ]
    for name, check, why in ro_checks:
        try:
            ok = check()
        except Exception:
            ok = False
        if ok:
            print(f"  {tag_up('UP'):12s} {name}")
        else:
            degraded += 1
            print(f"  {tag_warn('DEGRADED'):12s} {name} (report-only: {why})")

    print(
        f"  -> heal complete: {'all toolsets healthy' if degraded == 0 else f'{degraded} still degraded'}"
    )
    return degraded == 0


# ---- mc runs / mc costs -----------------------------------------------------


def _read_jsonl(path):
    rows = []
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    rows.append(json.loads(line))
                except Exception:
                    pass
    except OSError:
        pass
    return rows


def cmd_runs(n=20):
    rows = _read_jsonl(RUNS_LOG)[-n:]
    print(f"mc runs :: last {len(rows)} mc invocations (log: {RUNS_LOG})")
    if not rows:
        print("  no run rows yet")
        return
    agg = {}
    for r in rows:
        argv = r.get("argv") or ["?"]
        key = argv[0] if argv else "?"
        a = agg.setdefault(key, {"n": 0, "ms": 0.0})
        a["n"] += 1
        a["ms"] += r.get("wall_ms") or 0
    for key, a in sorted(agg.items(), key=lambda kv: -kv[1]["ms"]):
        avg = a["ms"] / a["n"]
        print(f"  {key:8s} runs={a['n']:3d} total={a['ms'] / 1000:7.1f}s avg={avg:7.1f}ms")
    print("  rows detail: mc runs shows recent rows below")
    for r in rows[-5:]:
        print(f"    {r.get('ts')} {' '.join(r.get('argv') or [])} {r.get('wall_ms')}ms")


def cmd_costs(n=50):
    print("mc costs :: estimated cost rows (ALL figures are ESTIMATES, never billed amounts)")
    entries = []
    for r in _read_jsonl(RUNS_LOG)[-n:]:
        if r.get("model"):
            entries.append(
                (
                    r.get("ts"),
                    "mc:" + " ".join(r.get("argv") or []),
                    r.get("model"),
                    r.get("est_in_tokens"),
                    r.get("est_out_tokens"),
                    r.get("est_usd"),
                )
            )
    for e in _read_jsonl(EVAL_LOG)[-n:]:
        for t in e.get("tests") or []:
            c = t.get("cost")
            if c and c.get("model"):
                entries.append(
                    (
                        e.get("ts"),
                        "eval:" + t.get("name"),
                        c.get("model"),
                        c.get("est_in_tokens"),
                        c.get("est_out_tokens"),
                        c.get("est_usd"),
                    )
                )
    if not entries:
        print("  no costed runs yet (most stack ops make no LLM call)")
        return
    total = 0.0
    for ts, what, model, it, ot, usd in entries:
        total += usd or 0.0
        print(f"  {ts} {what} model={model} in={it} out={ot} est=${(usd or 0.0):.6f} [ESTIMATE]")
    print(f"  -> total est. ${total:.6f} across {len(entries)} rows [ESTIMATE]")


def _dispatch(args):
    """Returns process exit code."""
    if not args or args[0] == "status":
        print(bold("mission-control :: agent-stack status"))
        sections = [
            ("traces", traces_summary),
            ("langsmith", langsmith_status),
            ("agent_stack", agent_stack_status),
            ("code_factory", code_factory_status),
            ("runtime", runtime_status),
            ("connectors", connectors_summary),
            ("nvidia", nvidia_status),
            ("tailscale", tailscale_status),
            ("gstack_adopted", gstack_adopted_status),
        ]
        ok_count = 0
        for name, fn in sections:
            if fn():
                ok_count += 1
        total = len(sections)
        banner = format_summary_banner(total=total, ok=ok_count, degraded=total - ok_count)
        print(banner)
        return 0
    elif args[0] == "traces":
        n = int(args[1]) if len(args) > 1 and args[1].isdigit() else 5
        traces_summary(n)
        return 0
    elif args[0] == "eval":
        return 0 if cmd_eval() else 1
    elif args[0] == "heal":
        return 0 if cmd_heal() else 1
    elif args[0] == "runs":
        n = int(args[1]) if len(args) > 1 and args[1].isdigit() else 20
        cmd_runs(n)
        return 0
    elif args[0] == "costs":
        n = int(args[1]) if len(args) > 1 and args[1].isdigit() else 50
        cmd_costs(n)
        return 0
    else:
        print(__doc__.strip())
        return 2


def main():
    t0 = time.time()
    code = _dispatch(sys.argv[1:])
    try:
        log_run(sys.argv[1:], (time.time() - t0) * 1000)
    except Exception:
        pass
    sys.exit(code)


if __name__ == "__main__":
    main()
