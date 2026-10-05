---
name: context-discipline
description: Use when a task involves heavy file reading, repo-wide search, or long tool output. Practices that keep the context window lean so sessions go further before compaction.
origin: arkira
---

# Context Discipline

Behavioral guidance for keeping tool output bounded. Apply it during any
read-heavy or search-heavy task.

## When to Use

- Before grepping or globbing across a large repo.
- When you are about to read the same file again.
- When a task fans out across many files.

## Practices

- **Search narrow.** Prefer a scoped `Grep` path/glob over a repo-wide sweep;
  a tight query is cheaper than a large result set.
- **Bound output at the source.** Narrow commands and searches before running
  them so large results do not enter the context window.

## Red Flags

- A Grep/Glob result longer than the screen pasted straight into reasoning.
- Reading entire directories "for context" before knowing what you need.

## Cross-references

- RTK owns shell-command output. Bound all other output at its source.
