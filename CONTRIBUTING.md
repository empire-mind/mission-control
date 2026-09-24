# Contributing to mission-control

Thanks for considering a contribution. This repo is maintained by one human
plus a small fleet of AI agents — the funnel below is designed so a stranger
can land a first PR in an evening.

## Maintainer SLA

**We give every issue and external PR a first response within 7 calendar
days.** That first response is a human-or-agent triage: confirmed, scoped,
or closed with a reason. If we ever miss the SLA, say so on the issue —
that's a bug in our process, not your problem.

Security reports are handled separately — see `SECURITY.md` (org default).

## Picking something to work on

- Issues labeled **`good first issue`** are scoped to be completable in an
  evening by someone new to the codebase. Each one names the files involved
  and what "done" looks like.
- Issues labeled **`help wanted`** are bigger and genuinely wanted, but need
  more context — comment first and we'll scope it with you.
- No issue for your idea? Open one (feature request template) before writing
  code, so we don't waste your evening.

## Workflow

1. Fork the repo, create a branch: `git checkout -b fix/short-name`
2. Make the change. Keep it small — one PR, one concern.
3. Run the checks: `./mc eval && python3 -m py_compile mc`
4. Commit with a clear message, push, open a PR against `main`.
   The PR template walks you through what to include.
5. A maintainer reviews within the SLA above. Expect questions, not silence.

## Ground rules

- **No secrets.** Never commit tokens, keys, passwords, or credentials —
  not in code, tests, fixtures, or commit messages.
- **Stdlib-first.** This repo prefers zero dependencies. A new dependency
  needs a justification in the PR and must not phone home at runtime.
- **Docs with behavior.** User-facing changes update the README or `docs/`.
- **Honest tests.** Tests must run for real — no mocks standing in for the
  thing being tested, no assertions that can't fail.
- **Be kind.** The Code of Conduct (Contributor Covenant, org default)
  applies everywhere in this repo.

## Dev setup

Python 3.8+. Stdlib-only — no install step:

```bash
git clone https://github.com/empire-mind/mission-control.git
cd mission-control
./mc status    # expect "not found" lines on a fresh machine — that's by design
./mc eval      # self-test suite, must pass before you open a PR
```

Note: on a machine without the empire-mind estate, several sections report
"not found". Improving those messages (one-line hints instead of bare
"not found") is a great first PR — see the graceful-degrade issues.
