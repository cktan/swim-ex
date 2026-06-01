---
name: sync-docs
description: Use after code changes to keep project documentation in sync. Updates the project's document md files — every *.md except the issue-tracker-managed HISTORY.md and P0–P3.md (DESIGN.md, README.md, USAGE.md, CLAUDE.md, and others) — to match the current state of the code. Invoke with /sync-docs.
---

You are synchronizing the swim-ex project documentation to match recent code changes.

## Step 1 — Understand what changed

Run these to see the current state:
```
git diff HEAD          # uncommitted changes
git diff main..HEAD    # all changes on this branch vs main
git status             # any untracked files
```

Focus on which source files under `lib/swim_ex/` changed, and what the
nature of the change was (new function, renamed function, new module,
changed behavior, changed config, changed wire format, etc.).

## Step 2 — Identify which docs are stale

**Scope — what "the docs" / "document md files" means:** every `*.md`
file in the repo root **except** the issue-tracker–managed set
(`HISTORY.md`, `P0.md`, `P1.md`, `P2.md`, `P3.md`, which are edited
only via the `issue-tracker` skill). `CLAUDE.md` is in scope.
`INVESTIGATE.md` is a historical audit snapshot — update it only when
explicitly asked. The generated `doc/` files are produced by `mix docs`
and are **not** hand-edited.

Use this map to decide which docs to update. If a change touches
behavior described in any in-scope doc not listed here, update that doc
too.

| Changed area | Docs to update |
|---|---|
| `lib/swim_ex/protocol.ex` — failure detection, ping/ack/ping_req flow, suspicion, leave | DESIGN.md (Protocol section), README.md, USAGE.md |
| `lib/swim_ex/membership.ex` — member state, incarnation, events | DESIGN.md (Membership section) |
| `lib/swim_ex/gossip_queue.ex` — gossip piggybacking, transmit limit, packing | DESIGN.md (Gossip section) |
| `lib/swim_ex/codec.ex` — wire format, message shapes | DESIGN.md (Wire format / Codec section) |
| `lib/swim_ex/transport.ex` or `transport/udp.ex` — transport behaviour or UDP impl | DESIGN.md (Transport section), USAGE.md |
| `lib/swim_ex/supervisor.ex` or `lib/swim_ex.ex` — public API, startup, supervision | README.md, USAGE.md, DESIGN.md (Supervision section) |
| Config keys or tunables changed (ping_timeout, ping_req_fanout, etc.) | DESIGN.md (Configuration section), USAGE.md |
| New file added | README.md (if public-facing), DESIGN.md (Module map) |
| File removed | DESIGN.md (Module map) |

## Step 3 — Update each stale doc surgically

For each doc that needs updating:

1. Read the relevant section(s) of the doc (not the whole file unless
   it's small).
2. Read the current source code to confirm exact behavior.
3. Make the minimum edit that makes the doc accurate. Do NOT rewrite
   sections that are still correct.
4. Do NOT change the style, formatting conventions, or level of detail
   of the existing doc.

**Specific rules per doc:**

**DESIGN.md** — Read the specific section heading that covers the
changed component. Update facts, remove outdated claims, add new
behavior. Do not touch unrelated sections.

**README.md** — Update only if the public API surface, install
instructions, or high-level behavior description changed.

**USAGE.md** — Update if the configuration options, startup sequence,
or usage examples changed.

**CLAUDE.md** — Update if naming conventions, key invariants, run
commands, or AI-agent guidelines changed.

## Step 4 — Report what you changed

List each doc you updated and the specific section(s) you changed. If a
doc was already accurate, say so explicitly. Do not commit — let the
user review first.
