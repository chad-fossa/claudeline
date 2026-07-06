# validator/CLAUDE.md — repo-specific validation guidance

This doc is human-authored, repo-specific guidance for the `validator` agent.
It is COMPLEMENTARY to the auto-discovered `run-plan.yaml` (machine state) — it
does not replace it. The validator reads this file at Phase 1 (discovery +
classification) to inform tier decisions and flag known hazards before running
anything.

**Location (mode-aware):**
- Local mode: `.claude/local/validator/CLAUDE.md` (gitignored, per-user)
- Shared mode: `.claude/validator/CLAUDE.md` (committed, team-shared)

> **Local-mode limit:** in local mode this doc is per-user (gitignored). Any
> shared-safety content — e.g. "never run the prod seed" guardrails — belongs in
> shared mode or the repo's own committed docs so teammates can't miss it.

---

<!-- cf:managed-start -->
<!-- This section is managed by change-factory. Doctor reconcile edits only inside
     these fences; content outside is yours and is never touched. -->

## Plugin scaffold (v{{PLUGIN_VERSION}})

Sections below are prompts — fill them in for this repo. Delete a section heading
if it genuinely does not apply; the validator treats an absent section as
no-guidance (not a failure).

<!-- cf:managed-end -->

---

## Manual exercise plan

How to manually trigger the running system for this repo — read by the validator at
Phase 1 to inform the mandatory manual exercise it produces (Phase 5). The
"Canonical validate command" section above is the start-recipe; this section covers
the trigger + what to look for once the app is running. Fill in the sub-sections
that apply; leave the others blank or remove them.

**Setup** — precursor state after the app is running (seed data, env vars, auth tokens):

```
# export APP_ENV=test DATABASE_URL=postgres://localhost:5432/myapp_test
# bin/seed-test-data
```

**Trigger** — exact command(s) or click path to fire at the RUNNING system:

```
# curl -s http://localhost:3000/api/health | jq .
# # Or for UI: open http://localhost:3000 → click "Sign in" → fill test@example.com / password
```

**Look** — where to observe the result (log line / endpoint / file / UI element):

```
# docker compose logs app --tail=20
# curl -s http://localhost:3000/api/status
```

**Expect** — success AND failure signals:

```
# Success: {"status":"ok","version":"..."} in response body; exit 0
# Failure: HTTP 5xx or {"error":...}; check logs for FATAL lines
```

---

## Boot environment variables

List env var NAMES and non-secret defaults the validator should know about.
**Never put real credentials here** — names + non-secret defaults only. This file
is committed in shared mode and visible to anyone who clones the repo.

```
# Example — replace or remove:
# DATABASE_URL=postgres://localhost:5432/myapp_test
# REDIS_URL=redis://localhost:6379
# APP_ENV=test
```

---

## Never-run guardrails

Commands or scripts that MUST NOT be executed in a local/CI validate run,
even if they look like a test or a setup step. State the reason so the validator
can explain the refusal.

```
# Example — replace or remove:
# db:seed:production — seeds production data; destructive and irreversible
# deploy:prod — triggers a real production deployment
```

---

## Canonical validate command

**REQUIRED for repos with a runnable surface.** This is the validator's PRIMARY
source for how to start the app — it takes priority over package.json / Makefile /
CI config / README discovery. If absent, the validator falls back to auto-discovery
(which may be ambiguous). A pure-docs repo with no runnable surface may state
`# no runnable surface` here instead.

This command is tier-classified by the validator like any other — a destructive or
prod-reaching start command will gate (YELLOW) or be refused (RED); being canonical
does NOT auto-trust it.

REQUIRED = the validator resolves + records a start-recipe; it is not gate-enforced
that you fill this section (the lint checks only the heading exists). NOTE: this
OPTIONAL→REQUIRED upgrade (v0.83.0) reaches new Inits; an already-initialized repo's
canonical section is outside the cf:managed fence, so Doctor will not backfill it —
fill it on upgrade.

Fill in the single command (or ordered sequence) that boots this repo locally so
the changed codepath can be exercised:

```
# make dev-up
# docker compose up -d && sleep 5
```

---

## Known-flaky areas

Tests, scripts, or services that are known to be flaky (intermittently failing for
reasons unrelated to the change). The validator uses this to decide whether a
single failure is signal or noise.

```
# Example — replace or remove:
# tests/e2e/billing.spec.ts — flaky due to Stripe sandbox timing; re-run 1x before escalating
# make test:redis — occasionally fails if Redis is slow to start; retry after 5s
```

---

## Teardown gotchas

Known issues with teardown that the validator's reaper should be aware of — stale
containers, locked ports, volumes that don't clean up automatically, etc.

```
# Example — replace or remove:
# docker compose down -v is required (plain 'down' leaves the postgres volume)
# Port 5432 may be held by a host postgres; check before starting the compose stack
```

---

## What "green" means for this repo

Describe the success signal for a local validate run. What does a passing run
produce? What can be safely ignored (expected warnings, skipped suites, etc.)?

```
# Example — replace or remove:
# Green = manual exercise executed (curl returns 200 + expected body) AND unit tests
# pass (supplement). e2e suite is optional (requires live Stripe keys — VALIDATION
# UNKNOWN is the correct signal when keys are absent).
# The "deprecated API" warning in the postgres driver is expected and harmless.
```
