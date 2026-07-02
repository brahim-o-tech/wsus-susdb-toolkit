# Contributing

Thanks for considering a contribution to the WSUS SUSDB Maintenance Toolkit.
This is an operational T-SQL script that runs against production
infrastructure — the bar for changes is correctness and safety first,
features second.

## Before you start

- For anything beyond a typo fix, please open an issue first to discuss the
  change. This avoids wasted effort on a pull request that doesn't align
  with the project's safety-first design principles (see README —
  destructive operations are opt-in, undocumented system procedures are not
  used, etc.).
- Check existing issues and the [CHANGELOG](CHANGELOG.md) before proposing
  something that may already be tracked or intentionally rejected.

## Design principles this project will not compromise on

1. **No undocumented SQL Server system procedures** (`sp_MSforeachtable`,
   `sp_MSforeachdb`, or similar). Use documented catalog views and dynamic
   SQL instead.
2. **Destructive or expensive operations stay opt-in**, off by default. The
   two heaviest operations (full rebuild, live decline) require a second,
   explicit confirmation flag — do not remove this pattern.
3. **Every critical and per-item operation is wrapped in `TRY...CATCH`.** A
   single failure must never silently abort an entire maintenance pass
   without being logged.
4. **No permanent objects added to SUSDB.** Logging and configuration stay
   session-scoped (`SESSION_CONTEXT`, local temp tables). If you have a case
   for a permanent table, open an issue to discuss the trade-off first — it
   changes the project's operating model significantly (MAJOR version bump).
5. **Compatibility level is only ever raised, never forced to a hardcoded
   value, never lowered.**

## How to propose a change

1. Fork the repository and create a branch from `main`.
2. Make your change in `sql/WSUS-SUSDB-Maintenance.sql`.
3. Test it manually against a **disposable lab WID or SQL Server instance**
   restored from a SUSDB backup — never against production. There is no
   automated CI for this project (T-SQL against a real WSUS schema doesn't
   lend itself to a public test harness), so manual verification is
   mandatory.
4. Fill out the PR checklist below.
5. Update `CHANGELOG.md` under an `[Unreleased]` heading.
6. Open a pull request describing what changed and why, referencing any
   related issue.

### PR checklist

- [ ] Tested against a real WID or SQL Server instance restored from a
      SUSDB backup (not production)
- [ ] Ran the full script top-to-bottom in a single session with default
      configuration — no errors
- [ ] If a new `SESSION_CONTEXT` flag was added, it's documented in
      `README.md` under "Configuration reference"
- [ ] If behavior changed, `CHANGELOG.md` is updated
- [ ] No undocumented system procedures introduced
- [ ] Destructive/expensive additions default to OFF

## Reporting bugs

Open a GitHub issue with:
- SQL Server / WID version (`SELECT @@VERSION;`)
- The section of the script involved
- The relevant rows from `#MaintenanceLog` and `#ErrorDetail` (redact any
  sensitive update titles/hostnames if needed)
- Steps to reproduce

For anything that could be a **security** issue (e.g. a SQL injection
vector in the dynamic SQL), see [SECURITY.md](SECURITY.md) instead of
opening a public issue.

## Style

- Keep the existing formatting conventions (uppercase T-SQL keywords,
  section banner comments, `SESSION_CONTEXT`-driven configuration).
- Comment the *why*, not just the *what* — this script is meant to be
  understandable by an admin who doesn't write T-SQL daily.
