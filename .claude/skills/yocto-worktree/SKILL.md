---
name: yocto-worktree
description: "Sets up, seeds, coordinates, and cleans up isolated git worktrees for subagent or parallel Yocto work in this repo. Use when delegating build-running or build-polluting tasks to a subagent, running a parallel session alongside the main checkout, renaming a worktree branch before opening a PR, or removing a locked agent worktree. Covers kas/local.yml seeding, shared-cache verification, rename-before-PR ordering, and double-force cleanup."
argument-hint: "[setup|verify-cache|rename|cleanup]"
allowed-tools: "Read, Grep, Glob, Bash(git *), Bash(cp *), Bash(ls *), Bash(test *), Bash(. scripts/env.sh*), Bash(kas *), Bash(gh *), Bash(.claude/skills/yocto-worktree/scripts/*)"
---

# Isolated Yocto worktrees (subagents & parallel sessions)

Orient with `git worktree list` and `test -f kas/local.yml` before
acting — the seeding step below depends on both.

## When to use a worktree (and when not)

Spawn subagents with `isolation: worktree` when the task:

- runs a build (anything invoking `make`/`bitbake`), or
- risks polluting `build/` or `.kas/` in the main checkout, or
- must run in parallel with the operator's own work in the main checkout.

Do **not** pay the worktree cost for read-only exploration or small
non-build edits — run those in place. Subagents cost extra context and
setup time; parallelism or isolation must justify them (see AGENTS.md
"Working economically").

The agent gets its own checkout under `.claude/worktrees/agent-<id>/`
and a branch named `worktree-agent-<id>`.

## 1. Seed and verify — run the script

`kas/local.yml` is gitignored, so a fresh worktree does **not** have it.
Without it, `make` falls back to `kas/rauc.yml` and the build won't use
the shared `DL_DIR`/`SSTATE_DIR` — a cold build takes hours instead of
the minutes an sstate-hit build takes.

From the **main checkout root**, run:

```bash
.claude/skills/yocto-worktree/scripts/seed-and-verify.sh .claude/worktrees/agent-<id>
```

The script copies `kas/local.yml` into the worktree, pins
`KAS_WORK_DIR`/`KAS_BUILD_DIR` to worktree-local paths, then resolves
`DL_DIR`/`SSTATE_DIR` through kas (sourcing `scripts/env.sh` — agent
shells don't get direnv) and fails if the checkout is not inside the
worktree or if either cache points inside the worktree's own `build/`.

### What may be shared, and what must never be

| Variable | Share? | Why |
|---|---|---|
| `DL_DIR` | **Yes** | Downloads; concurrent access is safe by design. |
| `SSTATE_DIR` | **Yes** | sstate objects; safe for concurrent read/write. |
| `KAS_REPO_REF_DIR` | **Yes** | Bare-repo git alternates, read-only. |
| `KAS_WORK_DIR` | **NEVER** | The layer **checkout**. Two kas runs sharing it check the layers out to *different pins*, and the second silently rewrites the first's metadata mid-build. |
| `KAS_BUILD_DIR` | **NEVER** | One `bitbake.lock` per build tree. |

**Sourcing `scripts/env.sh` is not sufficient protection.** It derives
`KAS_WORK_DIR` from its own location — which would be worktree-local —
but it honours a pre-set value (`${KAS_WORK_DIR:-…}`). A shell that
already carries the main checkout's export keeps pointing at the main
`.kas/`. Export both variables explicitly, in every shell, before any
`kas`/`make`/`bitbake` call in a worktree:

```bash
export KAS_WORK_DIR="$PWD/.kas" KAS_BUILD_DIR="$PWD/build"
```

**The failure mode does not look like a coordination problem.** The
*other* build — the one you are not running — reports `the basehash
value changed … metadata is not deterministic` against unrelated
recipes, then dies on a `FileNotFoundError` for a recipe that exists at
one pin but not the other. Nothing points at the worktree. Diagnose it
with `git -C .kas/openembedded-core reflog --date=iso`: an unexplained
`checkout: moving from <pinA> to <pinB>` during someone else's build is
the signature.

- Exit 0 — caches wired, safe to build.
- Exit 1 — prerequisites missing. If it reports `kas/local.yml` missing
  in the main checkout, **stop and ask the operator**; don't invent
  cache paths and don't start a cold build.
- Exit 2 — verification failed. Fix seeding and re-run. If it fails
  twice, stop and report: something structural is wrong, and repeated
  cold-build attempts are the expensive failure mode this skill exists
  to prevent.

Validate work progressively before any image build: `make parse`, then
the affected recipe's task, then the image (AGENTS.md "Working
economically").

## 2. Branch naming — rename before opening the PR

The default `worktree-agent-<id>` is opaque. Rename to the project's
`<type>-<scope>-<subject>` style (matching commit-subject + existing
branches like `feat-rauc-pki-yubikey-stage1`) **before** opening a PR.

GitHub's branch-rename API auto-redirects refs, but it **auto-closes any
open PR whose head ref is the old name** — you can't reopen because the
old ref is gone. So the order is:

1. `git branch -m <new>` locally
2. `git push -u origin <new>`
3. `gh api repos/<owner>/<repo>/branches/<old>/rename -f new_name=<new>`
   (or just delete `<old>` since the local rename + push already moved
   the work)
4. **Then** `gh pr create` from `<new>` to `main`

If the PR is already open under the old name, expect to close it and
re-open from the renamed branch with a "Supersedes #N" note in the body.

## 3. Coordinating with a parallel session in the main checkout

A subagent in `.claude/worktrees/agent-<id>/` and a session in the main
checkout (repo root, different branch) don't share working-tree state —
they can run truly in parallel. Discipline:

- The worktree agent owns its branch and its `build/`. Don't reach
  across.
- The main-checkout session continues on its own branch; do **not**
  `git rebase`/`pull` it while the parallel agent is mid-edit. Wait for
  `git status` to be clean.
- Once the worktree's PR merges to `main`, rebase the main-checkout
  branch onto `main`. If neither branch touched the same paths, the
  rebase is conflict-free. Verify with
  `git diff origin/main...<branch> --name-only` against the merged paths
  first.

## 4. Cleanup

`git worktree remove` may refuse with `cannot remove a locked working
tree, lock reason: claude agent agent-<id> (pid …)` even after the agent
process has exited. The lock is the agent harness's, not git's, and
persists past the process. Use double-force:

```bash
git worktree remove -f -f .claude/worktrees/agent-<id>
```

This removes both the worktree directory and its branch metadata.
Confirm with `git worktree list`.

Never `rm -rf` a worktree directory directly — git's worktree metadata
goes stale and later `git worktree` operations misbehave.

## Safety rails / stopping conditions

- Don't launch full-image builds to validate recipe-level edits —
  progressive validation first.
- Don't clean up worktrees, branches, or build state you didn't create;
  surface them to the operator instead.
- Stop and report if seed-and-verify fails twice (see step 1).
