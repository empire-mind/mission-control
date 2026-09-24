# mission-control — one command to see your whole agent fleet

`mc status`. One pane. Stdlib only, zero dependencies. The `htop` of agent
fleets: traces, LangSmith cloud, fleet health, code-factory smoke, the
runtime plane, connectors, Tailscale — one screen, one command.

## 60-second demo

```bash
curl -o mc https://raw.githubusercontent.com/empire-mind/mission-control/main/mc
chmod +x mc
./mc status
```

## Honest status: dogfood, not product — yet

This was built as the status pane for the empire-mind agent stack, and it
shows: several sections read estate-specific paths (`~/workspace/org/…`,
a local LangSmith auth proxy, a Tailscale snapshot marker). On a machine
without that estate, those sections report "not found" instead of crashing
— graceful degradation is a design rule here, and where it isn't yet, that's
a `good first issue`.

The part worth stealing today is the *pattern*: one stdlib-only script,
one `section()` helper, each check a small function that prints and never
raises. Extracting that into a documented 10-line plugin contract is
tracked as an issue — it's the highest-leverage contribution on the board.

## Commands

| Command | What it does |
|---|---|
| `./mc status` | full one-pane status (8 sections) |
| `./mc traces [N]` | last N trace events from the local JSONL store |
| `./mc eval` | 7-test self-test suite; exits 1 on failure |
| `./mc heal` | restart downed local services (8 toolsets) |
| `./mc runs [N]` | per-invocation wall-time log summary |
| `./mc costs [N]` | estimated cost rows — every number labeled ESTIMATE |

## Design rules

- **Stdlib only.** If it needs pip, it doesn't belong in `mc`.
- **Never raise in a section.** A check that errors prints one line and
  moves on — a status pane that crashes is worse than no pane.
- **Estimates say ESTIMATE.** Cost rows are labeled as estimates, always.
- **60-second rule.** `curl` it, run it, see output. Setup longer than a
  minute is a bug.

## Development

```bash
./mc eval        # self-test suite, must pass
python3 -m py_compile mc
```

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Contributing

**Every issue and external PR gets a first response within 7 calendar
days.** `good first issue` items are scoped for one evening — the plugin
contract extraction and the graceful-degrade audit are the best places to
start. Full funnel in [CONTRIBUTING.md](CONTRIBUTING.md). Security issues:
see the org
[SECURITY.md](https://github.com/empire-mind/.github/blob/main/SECURITY.md).

## License

MIT — see [LICENSE](LICENSE).
