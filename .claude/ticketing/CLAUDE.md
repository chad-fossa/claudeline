# ticketing/CLAUDE.md — provider:other adapter description

This doc is used ONLY when `ticketing.provider: other` is set in `agent-lint.config`.
For `provider: jira`, the Jira MCP is the adapter — no config doc is needed.
If this file is present but `ticketing.provider` is not `other`, it is ignored.

**Location (mode-aware):**
- Local mode: `.claude/local/ticketing/CLAUDE.md` (gitignored, per-user)
- Shared mode: `.claude/ticketing/CLAUDE.md` (committed, team-shared)

> `ticketing.provider`, `ticketing.enabled`, and `ticketing.trailer-key` are
> authoritative in `agent-lint.config` (or `.claude/local/agent-lint.config`).
> On any conflict, lint.config wins for provider identity.
>
> `provider: other` + this file absent → one-line note + no-op (observability);
> the ticketing skill degrades silently, same as no-Jira-config.
>
> **verify-before-Done is provider-independent:** the Done transition requires
> a parseable `key-format` declared below; absent or unparseable → Done is a
> no-op (surfaced with one line), NEVER best-effort.

---

<!-- cf:managed-start -->
<!-- This section is managed by change-factory. Doctor reconcile edits only inside
     these fences; content outside is yours and is never touched. -->

## Plugin scaffold (v{{PLUGIN_VERSION}})

Sections below are prompts — fill them in for this repo. All fields in the
"Adapter schema" section are required for full ticketing operation.

<!-- cf:managed-end -->

---

## Adapter schema

### Provider name

The human name of your ticketing provider (e.g. Linear, GitHub Issues, Shortcut,
Asana). Used in surfaced messages only — has no effect on behavior.

```
provider-name: ticket-kit
```

### State → intent mapping

Map your provider's concrete workflow states to the four universal ticketing
intents. The ticketing skill probes your provider for available transitions
(probe-don't-hardcode) and uses this mapping to pick the right one. Use
case-insensitive matching; "n/a" if your provider has no equivalent state.

```
work-started:  in-progress   # edit `status:` frontmatter in tickets/TD-NNNN-*.md
in-review:     n/a           # ticket-kit has no review state; skip silently
done:          done          # set on a verified merge
split-for-small-prs: n/a     # no equivalent; skip silently
```

### Container model

Does your provider support a container concept (epic, parent issue, milestone)?
Describe it here. The ticketing skill closes the container only when ALL its
children are Done; if your provider has no container concept, write "none" and
container-completion probes are skipped entirely.

```
container: parent      # ticket-kit tickets may carry a `parent:` frontmatter field
```

### Key format (REQUIRED for Done)

A regex or example pattern the skill uses to parse and inject a work-item key into
commit trailers and branch names. REQUIRED — the Done transition is a no-op if this
is absent or unparseable.

```
key-format: "TD-[0-9]{4}"             # ticket-kit e.g. TD-0007; files at tickets/TD-NNNN-slug.md
```

### Trailer key

The commit-trailer key used to thread the work-item key through commits (overrides
`ticketing.trailer-key` in lint.config for this repo). Omit to use the lint.config
value (default: `Jira-Issue` for jira; set your own here for other providers).

```
# Example — replace or remove:
# trailer-key: Linear-Issue
# trailer-key: GitHub-Issue
```
