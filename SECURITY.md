# Security Policy

## Scope

This project is a T-SQL maintenance script, not a running service — the
relevant security surface is:

- Dynamic SQL construction (`EXEC(@command)` / `EXEC(@rebuildSql)` /
  `EXEC(@statSql)`)
- Required database/server permissions
- Any logic that could allow the script to act outside SUSDB, or with
  broader privileges than documented

## Supported versions

Only the latest tagged release receives security fixes. Please upgrade to
the latest version before reporting an issue.

| Version | Supported |
|---|---|
| Latest release | ✅ |
| Older releases | ❌ |

## Reporting a vulnerability

**Do not open a public GitHub issue for a suspected security problem.**

Instead, use GitHub's private vulnerability reporting
(**Security → Report a vulnerability** on this repository), or email the
maintainer directly. Include:

- A description of the issue and its potential impact
- The section of the script involved
- Steps to reproduce, ideally against a disposable lab SUSDB (never share
  production data, connection strings, or credentials)

You should receive an initial response within **5 business days**. This is
a community-maintained project without a dedicated security team — response
times are best-effort.

## What is (and isn't) a vulnerability here

**In scope:**
- A dynamic SQL construction path that could allow injection from a value
  not sourced from trusted system catalog views (`sys.tables`,
  `sys.indexes`, `sys.schemas`)
- A `SESSION_CONTEXT` flag or code path that could cause a destructive
  operation to run without its intended confirmation gate
- A permissions requirement broader than documented in `README.md`

**Out of scope (expected behavior, not a vulnerability):**
- The script requiring `db_owner`-equivalent permissions — this is
  documented and necessary for `ALTER DATABASE`, `ALTER INDEX`, and
  `sp_updatestats`
- Index rebuilds blocking concurrent access (inherent to offline rebuilds
  on non-Enterprise editions, not a flaw in this script)
- Issues in WSUS/SUSDB itself, or in `spDeclineUpdate` and other WSUS
  system objects this script calls — report those to Microsoft
