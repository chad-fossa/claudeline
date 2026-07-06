#!/usr/bin/env python3
"""cf-gate-record — write the Step-9 gate ledger for the current tree.

Run by the orchestrator ONLY after a real gate pass (review fixpoint zero-edits +
validate green on the same tree), by pr-shepherd's per-fix mini-gate, or by the
narrated escape-hatch light review. The verdict is part of the audit trail:

  green                    — review-clean + validated-green (the full Step-9 fixpoint, or a Tier-1 fan-out + validate)
  behavior-unvalidated-ack — VALIDATION UNKNOWN, user explicitly acked (per-change)
  shepherd-fix-green       — pr-shepherd body Step 4b mini-gate green
  light-reviewed           — escape-hatch lane (trivial direct edit, narrated light review)

Refuses to write when the ledger path is not gitignored (per-user state must never
be committed) or when the repo is not change-factory-managed.

SCOPE: part of an advisory guard against accidental gate-skips, not a security
boundary — the same actor that runs the gate records it; the hook makes the claim
explicit and durable, it cannot verify the gate ran WELL.
"""
import argparse
import datetime
import json
import os
import subprocess
import sys

VERDICTS = ["green", "behavior-unvalidated-ack", "shepherd-fix-green", "light-reviewed"]
TIMEOUT = 10
LEDGER_DIRNAME = "step9-ledger.d"
LEDGER_MAX_AGE_DAYS = 14


def git(cwd, *args):
    res = subprocess.run(
        ["git", "-C", cwd, *args], capture_output=True, text=True, timeout=TIMEOUT
    )
    return res.returncode, res.stdout.strip()


def fail(msg):
    sys.stderr.write(f"cf-gate-record: {msg}\n")
    return 1


def main(_git=git):
    parser = argparse.ArgumentParser()
    parser.add_argument("--verdict", required=True, choices=VERDICTS)
    args = parser.parse_args()

    cwd = os.getcwd()
    rc, common = _git(cwd, "rev-parse", "--path-format=absolute", "--git-common-dir")
    if rc != 0:
        return fail("not inside a git repository")
    root = os.path.dirname(common)

    managed = os.path.exists(
        os.path.join(root, ".claude", ".change-factory-version")
    ) or os.path.exists(os.path.join(root, ".claude", "local", ".change-factory-version"))
    if not managed:
        return fail("not a change-factory-managed repo — refusing to write a ledger")

    rel_check = os.path.join(".claude", "local", LEDGER_DIRNAME)
    rc, _ = _git(root, "check-ignore", rel_check)
    if rc != 0:
        return fail(
            f".claude/local/ is not gitignored — add `.claude/local/` to .gitignore first "
            "(the ledger is per-user state and must never be committed)"
        )

    rc, tree = _git(cwd, "rev-parse", "HEAD^{tree}")
    if rc != 0 or not tree:
        return fail("could not resolve HEAD^{tree}")

    ledger_dir = os.path.join(root, ".claude", "local", LEDGER_DIRNAME)
    os.makedirs(ledger_dir, exist_ok=True)
    path = os.path.join(ledger_dir, f"{tree}.json")
    with open(path, "w") as f:
        json.dump(
            {
                "tree": tree,
                "at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                "verdict": args.verdict,
            },
            f,
            indent=2,
        )
        f.write("\n")

    # Prune entries older than LEDGER_MAX_AGE_DAYS (age-based; best-effort).
    # A freshly-written file (mtime ≈ now) can never satisfy the age threshold.
    cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=LEDGER_MAX_AGE_DAYS)
    cutoff_ts = cutoff.timestamp()
    try:
        for name in os.listdir(ledger_dir):
            if not name.endswith(".json"):
                continue
            old_path = os.path.join(ledger_dir, name)
            try:
                if os.path.getmtime(old_path) < cutoff_ts:
                    os.remove(old_path)
            except Exception:
                pass
    except Exception:
        pass  # pruning is best-effort; never block a successful record

    print(f"cf-gate: recorded {args.verdict} for tree {tree[:12]}…")
    return 0


if __name__ == "__main__":
    sys.exit(main())
