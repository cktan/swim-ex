---
name: issue-tracker
description: Manage the project's issue tracking system (P0-P3 and HISTORY.md) using the automated issue.py tool. Use this when you need to open, close, move, or retrieve details for bugs and planned improvements.
---

# Issue Tracker

This skill provides an automated way to manage the project's issue tracking system, ensuring that issue counter and formatting invariants are maintained.

## Core Tool

Use the bundled Python script for all issue operations:

`python3 scripts/issue.py <command> [args]`

### Commands

- **Get Issue**: `python3 scripts/issue.py get <issue-id>`
  - Retrieves title, problem, and proposed fix/solution.
- **Open Issue**: `python3 scripts/issue.py open <P0|P1|P2|P3> "Title" "Problem" "Fix"`
  - Automatically assigns the next ID and updates the issue counter.
- **Close Issue**: `python3 scripts/issue.py close <issue-id> "fixed|ignored" "Solution"`
  - Moves the issue to `HISTORY.md` with the current date.
- **Move Issue**: `python3 scripts/issue.py move <issue-id> <P0|P1|P2|P3>`
  - Changes the priority by moving the issue between files.

## Guidelines

- **Prefer Automation**: Always use the script instead of manual Markdown edits to avoid breaking the `ISSUE_COUNTER` or formatting.
- **Priorities**:
  - `P0`: Critical / Blocking
  - `P1`: High Priority
  - `P2`: Medium Priority
  - `P3`: Low Priority
- **Consistency**: The script handles the `---` separators and `## Issue N — Title` format automatically.
