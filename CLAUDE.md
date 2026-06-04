# swim-ex — Claude Code Context

A SWIM-based membership protocol for Elixir.

See `DESIGN.md` for an overview of the project.

See `MANIFEST.md` for a map of source files and their purposes.

---

## Git workflow

- **Do not auto-create feature branches or merge into `main`
  without confirming the intended git workflow first; default to
  committing directly unless told otherwise.**
- **When merging a branch into `main`, use `git merge --squash`**
  so the branch's commits collapse into a single commit on
  `main`. Stage the result and commit with a message
  summarising the branch.

---

## Markdown formatting

When writing or editing any `.md` file, wrap prose paragraphs
so that no line exceeds 65 characters. This applies to body
text only — do not reformat code blocks, tables, or headings.

---

## Issue tracker

- **Do not manually edit `P0.md`, `P1.md`, `P2.md`, `P3.md`,
  or `HISTORY.md`** — use the `issue-tracker` skill
  (`.claude/skills/issue-tracker/scripts/issue.py`) to
  maintain id and formatting invariants.
- **When opening or closing any issue, invoke the
  `issue-tracker` skill** — do not call `issue.py` directly
  via Bash; always go through the skill so hooks and
  formatting rules are applied consistently.

---

## AI Agent Guidelines

### 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

### 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

### 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

### 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it 
work") require constant clarification.

---

## Test commands

- **Standard suite:** `mix test`
- **Scale/Stress suite:** `mix test test/swim_ex/scale_test.exs`
- **Coverage:** `mix test --cover`

See `QA.md` for a detailed description of the testing
infrastructure, fault injection, and scale scenarios.
