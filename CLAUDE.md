# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Project orientation, build commands, repo layout, conventions, and task routing live in the agent-agnostic file:

@AGENTS.md

The rest of this file is Claude-Code-specific tooling that does not apply to other agents.

## Domain skills available

Two repo-local skills in `.claude/skills/` — invoke when the task fits:

- `devtool-workflow` — iterating on recipe source (U-Boot, kernel, app) via `devtool` instead of hand-editing patches: `--no-overrides`, patch export destinations, mandatory contamination verification, the U-Boot savedefconfig flow
- `yocto-worktree` — isolated worktrees for subagent/parallel builds: `kas/local.yml` seeding, shared-cache verification, branch rename-before-PR, locked-worktree cleanup

A previous shared set (`add-package`, `build-image`, `debug-bitbake`,
`create-kernel-fragment`, `patch-kernel-bsp`, `patch-uboot-bsp`) was
removed: it was generic scarthgap-era procedure that restated
`AGENTS.md` and `.claude/rules/` less precisely, and its raw
`kas shell` examples contradicted the `scripts/env.sh` requirement.
BitBake failure triage now lives in `.claude/rules/yocto-patterns.md`.
Everything else those skills covered is in `AGENTS.md` and the rules —
read those instead.

## Subagents & parallel work

Delegate build-running or build-polluting tasks to subagents with `isolation: worktree`, and follow the `yocto-worktree` skill for seeding, coordination, and cleanup. Recipe/patch conventions live in `.claude/rules/recipe-conventions.md` (auto-loaded as a rule; also route subagents there explicitly).

Before starting build-running/build-polluting work or a substantial multi-file change yourself (not just when spawning a subagent), run `git status` first. If unrelated uncommitted changes from a different thread are already sitting in the tree, don't silently add to them — flag it and ask whether the new work should go in its own worktree instead. Skip this for minimal/single-file changes; bundle those per the normal PR-scope convention (`AGENTS.md` §Conventions).

## Commit trailers

The canonical rule is `AGENTS.md` §"AI attribution in commits": an
`Assisted-by: <tool>:<model-id>` line per model that touched the change. From
Claude Code that is `Assisted-by: claude-code:<the model id you are running as>`.

**Do not add `Co-Authored-By:` for an AI tool** — not in commits, not in PR
bodies. This overrides the harness default, which emits one; drop that line.
`Assisted-by:` already records the same participation and records it better:
it names the exact tool and model, one line per model in the order they
touched the change. `Co-Authored-By:` asserts conventional authorship by
something that cannot hold it, and duplicates a fact the line above states
precisely. One label, deliberately.

Applies to **new** commits from 2026-08-11 onward. Existing history keeps
whatever it carries — do not retrofit, amend or rewrite past commits to match.
A mixed history is honest; a rewritten one destroys the record the trailer
exists to provide.

**Do not copy a model name from this file or from a past commit.** This section
deliberately contains no literal model id — read your own model identity from
your instructions and write that. A pinned string goes stale silently and turns
the audit trail into fiction.

## Serial console + target diagnostics MCPs

Two MCP servers are wired for on-target work:

- `mcp-serial-rs` — direct UART access (`serial_list_ports`, `serial_open` on `/dev/ttyACM0`, `serial_exec`, `serial_read_until`). Prefer it for U-Boot/boot-flow debugging; close the port (`serial_close`) before the operator starts `tio`, they can't share the device.
- `mcp-netdiag-rs` — host-side network/system diagnostics (ping, routes, neighbors, sockets, dmesg, service status) for reaching and triaging the target.

The operator may still capture UART via `tio --log --log-directory $PWD/tio-session-logs /dev/ttyACM0` and share the log path. When grepping those logs, note that the file can contain high-bit / extended-ASCII control bytes that make vanilla `grep` skip lines it considers "binary". Use `grep -a` or `strings <log> | grep …` so U-Boot/firmware output isn't silently filtered out.
