# Mission Control Plugin Contract 🔌⚡

Mission Control (`mc`) is designed around a single guiding principle: **steal this for your fleet**.

Adding a check for your own services, pipelines, models, or daemons takes **10 lines of code**. Zero external dependencies, zero boilerplate.

---

## 1. The Core Contract Rules

Every check in `mc` must satisfy four non-negotiable rules:

1. **Stdlib-Only**: Never import external libraries. All checks must execute using Python standard library primitives (`subprocess`, `socket`, `os`, `json`, `time`).
2. **The Never-Raise Rule**: A check must **never raise an uncaught exception**. If a network socket drops, a binary is absent, or a file is corrupted, the check handles the exception internally, outputs a clean diagnosis, and returns `False`. A status pane that crashes on failure is worse than no status pane.
3. **Graceful Degradation & One-Line Hints**: When expected paths or binaries are missing (e.g. running on a new machine or empty home directory), print what was looked for and how to provide it on a single line (`expected <path>; <remedy>`).
4. **Standard Indentation & Tagging**: Section title is rendered using `section("title")`. Detail rows are indented with two spaces (`  `), using standard tags (`tag_ok`, `tag_warn`, `tag_err`, `tag_up`, `tag_info`).

---

## 2. The 10-Line Copy-Paste Runnable Example

Here is a complete, copy-paste runnable check for any custom service:

```python
def check_my_service() -> bool:
    """Check custom service status in 10 lines."""
    section("my-service")
    path = os.path.expanduser("~/workspace/my-service/config.json")
    if not os.path.exists(path):
        print(f"  {tag_err('not found')} (expected {path}; configure my-service)")
        return False
    try:
        up = tcp_open("127.0.0.1", 8080)
        print(f"  status: {tag_up('UP') if up else tag_err('DOWN')} | port: 8080")
        return up
    except Exception as e:
        print(f"  {tag_err('ERROR')}: {format_error(e)}")
        return False
```

---

## 3. Registering Your Check

To register your check into `mc status`, add your function tuple to the `sections` list in `_dispatch()`:

```python
sections = [
    ("traces", traces_summary),
    ("langsmith", langsmith_status),
    ("my_service", check_my_service),  # <-- your new check here
    ("code_factory", code_factory_status),
    ...
]
```

When registered, your check's boolean return value is automatically counted and aggregated into the **Across-The-Room Summary Banner**:
- `● ALL OPERATIONAL: N/N sections healthy`
- `▲ DEGRADED: X/N healthy (Y missing/degraded)`

---

## 4. Helper Primitives Reference

| Helper | Purpose | Graceful Degradation |
|---|---|---|
| `section(title)` | Renders ANSI cyan bar on TTY; `== title ==` on piped | Piped/non-TTY safe |
| `format_error(e, max_len=80)` | Formats `OSError` as `[Errno N] msg: path` without mid-path word splitting | Delimiter boundary truncation |
| `tcp_open(host, port, timeout=2)` | Fast TCP connection probe without hanging | Returns `False` on socket error |
| `tag_ok()`, `tag_warn()`, `tag_err()` | Colored brackets (`[OK]`, `[DEGRADED]`, `[ERROR]`) | Strips ANSI when not TTY / NO_COLOR |

---

## 5. Refactored Proof Implementation

In `mc`, `code_factory_status()` demonstrates this pattern in practice:
- Verifies binary existence before spawning subprocesses.
- Employs bounded timeouts (`timeout=30`, `timeout=5`).
- Uses `format_error(ex)` to prevent string truncation.
- Returns boolean health status for summary calculation.
