# swim-ex — Claude Code Context

<!-- Fill in: what this project is, language, key deps -->

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

- **Fix one issue at a time:** Complete the full
  plan-act-validate cycle for a single issue before moving
  to the next.
- **Verify starting state, surface tradeoffs before
  implementing:** Before writing code, confirm the starting
  state and present design tradeoffs for review rather than
  committing to one approach silently.
- **Verification:** Always run the full test suite before
  committing. It must pass.
