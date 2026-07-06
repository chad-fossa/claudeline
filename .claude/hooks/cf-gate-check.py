#!/usr/bin/env python3
"""cf-gate-check — PreToolUse hook: block `git push` without a Step-9 gate green.

Wired in .claude/settings.local.json (PreToolUse, matcher Bash). Reads the hook
payload on stdin, and exits:
  0 — allow (not a push / not a cf-managed repo / ledger matches / explicit bypass)
  2 — block (stderr is fed back to the agent)

Detection is segment-aware: the command is split on shell separators and a
segment counts as a push only when `git` is the segment-head program and `push`
is its SUBCOMMAND (so `git stash push`, `git config push.default`, filenames or
quoted strings containing "git push" — even with embedded `&&` — never match;
segmentation is shlex quote-aware, with a conservative raw-split fallback for
unbalanced-quote input such as heredoc fragments, where an over-block is possible
and the logged bypass is the remedy). The
gated tree is the tree of the refs actually being PUSHED (refspec-aware:
`git push origin src:dst` gates src's tree; bare `git push` falls back to HEAD).

A bypass requires CF_GATE_BYPASS=<reason> in the command itself — it is allowed
but APPENDED to .claude/local/gate-bypass.log ({at, reason, head}) so the Doctor
can report bypass usage; never silent.

SCOPE: an advisory guard against the agent's own accidental/rationalized gate
skips. NOT a security boundary — fail-open by design on infrastructure errors;
do not rely on it against a hostile actor (a human's own terminal is never gated).
"""
import datetime
import json
import os
import re
import shlex
import subprocess
import sys

TIMEOUT = 10
LEDGER_DIRNAME = "step9-ledger.d"
LEGACY_LEDGER = "step9-ledger.json"
RAW_SPLIT = re.compile(r"[;&|]+")
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
# git global options that consume the NEXT token when not =-joined
GIT_VALUE_OPTS = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path"}
# push options that consume the next token
PUSH_VALUE_OPTS = {"-o", "--push-option", "--repo", "--receive-pack", "--exec"}


def git(cwd, *args):
    res = subprocess.run(
        ["git", "-C", cwd, *args], capture_output=True, text=True, timeout=TIMEOUT
    )
    return res.returncode, res.stdout.strip()


def line_segments(line):
    """Quote-aware segmentation of one line into token lists, split at shell operators.

    Primary path uses shlex so a QUOTED string containing "git push … && …" stays one
    token and never looks like a push. Unbalanced quotes (heredoc fragments) fall back
    to raw-text splitting — conservative: may over-match, never under-tokenizes a real
    push (the bypass lane covers the rare over-block)."""
    try:
        lex = shlex.shlex(line, posix=True, punctuation_chars=";|&()")
        lex.whitespace_split = True
        toks = list(lex)
    except ValueError:
        return [seg.split() for seg in RAW_SPLIT.split(line) if seg.split()]
    segs, cur = [], []
    for tok in toks:
        if tok and not set(tok) - set(";|&()"):
            if cur:
                segs.append(cur)
                cur = []
        else:
            cur.append(tok)
    if cur:
        segs.append(cur)
    return segs


def push_refspecs(toks):
    """Return (is_push, refspecs[], cdir) for one token-list segment (cdir = `git -C` arg)."""
    i = 0
    while i < len(toks) and ASSIGNMENT.match(toks[i]):
        i += 1  # leading VAR=val assignments (e.g. CF_GATE_BYPASS=reason)
    if i >= len(toks) or os.path.basename(toks[i]) != "git":
        return False, [], None
    i += 1
    cdir = None
    while i < len(toks) and toks[i].startswith("-"):  # git global options
        if toks[i] == "-C" and i + 1 < len(toks):
            cdir = toks[i + 1]  # honor -C: the repo git actually operates on
        i += 2 if toks[i] in GIT_VALUE_OPTS else 1
    if i >= len(toks) or toks[i] != "push":
        return False, [], None
    i += 1
    positionals = []
    while i < len(toks):
        tok = toks[i]
        if tok.startswith("-"):
            i += 2 if tok in PUSH_VALUE_OPTS else 1
            continue
        positionals.append(tok)
        i += 1
    return True, positionals[1:], cdir  # positional[0] is the remote; rest are refspecs


def trees_to_gate(cwd, refspecs, _git=git):
    """Resolve the tree hash of each pushed ref; fall back to HEAD."""
    srcs = []
    for spec in refspecs:
        src = spec.split(":", 1)[0].lstrip("+")
        if not src:
            continue  # ':dst' deletion push — no tree ships
        srcs.append(src)
    if not srcs:
        if refspecs:
            return set()  # deletion-only push: nothing ships — allow
        srcs = ["HEAD"]  # bare push / --tags / --all
    trees = set()
    for src in srcs:
        rc, tree = _git(cwd, "rev-parse", f"{src}^{{tree}}")
        if rc != 0 or not tree:
            rc, tree = _git(cwd, "rev-parse", "HEAD^{tree}")  # conservative fallback
            if rc != 0 or not tree:
                return None
        trees.add(tree)
    return trees


def log_bypass(root, command, pin_fails=None):
    reason = "unstated"
    m = re.search(r"CF_GATE_BYPASS=(\S+)", command)
    if m:
        reason = m.group(1)
    try:
        path = os.path.join(root, ".claude", "local", "gate-bypass.log")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        entry = {
            "at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "reason": reason,
            "head": command.strip()[:120],
        }
        if pin_fails:
            entry["pin_fails"] = pin_fails[:800]  # bypassed-but-failing pins: visible to the Doctor
        with open(path, "a") as f:
            f.write(json.dumps(entry) + "\n")
    except Exception:
        pass  # logging must never block the allowed bypass


def main(_git=git):
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return 0  # malformed payload: never block on our own bug
    command = (payload.get("tool_input") or {}).get("command") or ""

    push_specs = None
    push_cdir = None
    for line in command.split("\n"):
        for toks in line_segments(line):
            is_push, specs, cdir = push_refspecs(toks)
            if is_push:
                push_specs = specs if push_specs is None else push_specs + specs
                push_cdir = cdir or push_cdir
    if push_specs is None:
        return 0  # no real git-push invocation in any segment

    cwd = payload.get("cwd") or os.getcwd()
    if push_cdir:  # `git -C <path> push` operates on <path>'s repo, not the cwd's
        cwd = push_cdir if os.path.isabs(push_cdir) else os.path.join(cwd, push_cdir)
    try:
        rc, common = _git(cwd, "rev-parse", "--path-format=absolute", "--git-common-dir")
        if rc != 0:
            return 0  # not a git repo: nothing to gate
        root = os.path.dirname(common)
        managed = os.path.exists(
            os.path.join(root, ".claude", ".change-factory-version")
        ) or os.path.exists(
            os.path.join(root, ".claude", "local", ".change-factory-version")
        )
        if not managed:
            return 0  # not a change-factory repo: stay inert
        # workflowModelPinning (plugin repo only): an unpinned workflow dispatch silently runs at
        # the SESSION model — block the push, don't rely on the self-policed lint pass (2026-07-03).
        # ALLOW requires the checker's POSITIVE GREEN sentinel (rc 0 + "GREEN"); a crash, odd exit,
        # or empty output BLOCKS — a content-driven checker crash is contributor input, not
        # infrastructure (gate finding, round 3). Timeout/spawn failure falls to the outer
        # fail-open. Under CF_GATE_BYPASS the checker still RUNS for visibility: failures are
        # appended to the bypass log entry (never silent), but the logged bypass is honored.
        checker = os.path.join(root, "resources", "hooks", "check-model-pinning.py")
        pin_fails = None
        if os.path.isdir(os.path.join(root, "workflows")) and os.path.exists(checker):
            res = subprocess.run(
                [sys.executable, checker], capture_output=True, text=True, timeout=TIMEOUT
            )
            pin_ok = res.returncode == 0 and "GREEN" in res.stdout
            pin_fails = None if pin_ok else (res.stdout.strip() or res.stderr.strip()[-800:] or "checker produced no output")
        if "CF_GATE_BYPASS=" in command:
            log_bypass(root, command, pin_fails=pin_fails)
            return 0  # explicit + logged (incl. any pinning failures); the Doctor reports usage
        if pin_fails is not None:
            sys.stderr.write(
                "cf-gate: BLOCKED — workflow model-pinning did not report GREEN "
                "(resources/hooks/check-model-pinning.py):\n"
                + pin_fails
                + "\n  Fix the pins (a checker crash also blocks: crash is a verdict, not an escape).\n"
                "  Emergency lane: CF_GATE_BYPASS=<reason> git push … (bypass is LOGGED with the failures).\n"
            )
            return 2
        trees = trees_to_gate(cwd, push_specs, _git=_git)
        if trees is None or not trees:
            return 0  # unresolvable (fail-open) or deletion-only (nothing ships)
    except Exception:
        return 0  # fail-open on infrastructure errors, never wedge unrelated work

    ledger_dir = os.path.join(root, ".claude", "local", LEDGER_DIRNAME)
    legacy_path = os.path.join(root, ".claude", "local", LEGACY_LEDGER)

    def tree_is_gated(tree):
        """Return True if tree has a recorded gate green (fail-open on errors)."""
        # Primary: per-tree file in .d/ directory
        per_tree = os.path.join(ledger_dir, f"{tree}.json")
        if os.path.exists(per_tree):
            try:
                with open(per_tree) as f:
                    data = json.load(f)
                if data.get("tree") != tree:
                    return False  # tree-field mismatch: not gated (defense-in-depth)
                return True
            except Exception:
                return True  # corrupt file: fail-open (treat as gated)
        # Back-compat: legacy single step9-ledger.json
        if os.path.exists(legacy_path):
            try:
                with open(legacy_path) as f:
                    ledger = json.load(f)
                if ledger.get("tree") == tree:
                    return True
            except Exception:
                return True  # corrupt legacy: fail-open
        return False

    ungated = [t for t in trees if not tree_is_gated(t)]
    if not ungated:
        return 0

    # Describe ledger state for the error message
    if os.path.isdir(ledger_dir) and os.listdir(ledger_dir):
        state = f"has {len(os.listdir(ledger_dir))} entry/entries (none match)"
    elif os.path.exists(legacy_path):
        try:
            with open(legacy_path) as f:
                ledger = json.load(f)
            state = f"stale (recorded {str(ledger.get('tree'))[:12]} as {ledger.get('verdict')})"
        except Exception:
            state = "unreadable"
    else:
        state = "missing"

    shown = ", ".join(sorted(t[:12] for t in ungated))
    sys.stderr.write(
        "cf-gate: BLOCKED — no Step-9 gate green recorded for the tree being pushed.\n"
        f"  pushed tree(s): {shown}…   ledger: {state}\n"
        "  Run the Step-9 ship gate (review fixpoint + validate), then record it:\n"
        "    python3 <hooks-dir>/cf-gate-record.py --verdict green\n"
        "  Any post-gate edit/rebase changes the tree — re-gate; never re-record blindly.\n"
        "  Explicit logged bypass (chore pushes / human-directed emergency):\n"
        "    CF_GATE_BYPASS=<reason> git push …\n"
    )
    return 2


if __name__ == "__main__":
    sys.exit(main())
