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

- **Trust prior reads.** A file you already read this session is in context. Do
  not re-read it to "be sure". Re-reading is the single most common token leak.
- **Delegate only when it compresses the work.** Use the `explorer` agent for an
  independent, bounded search whose conclusion is materially smaller than its
  inputs. Keep simple lookups inline; dispatch overhead is not free.
- **Search narrow.** Prefer a scoped `Grep` path/glob over a repo-wide sweep;
  large result sets get compressed anyway, but a tight query is cheaper still.
- **Bound output at the source.** Narrow commands and searches before running
  them so large results do not enter the context window.

## Rationalizations (do not accept these)

| Excuse | Reality |
|--------|---------|
| "Let me re-read the file to be safe." | It is already in context. Re-reading wastes tokens and changes nothing. |
| "I'll just grep the whole repo." | A scoped query answers the question for a fraction of the tokens. |
| "I need the full file dump in the main thread." | A subagent can read it and return the answer. The dump is liability. |

## Red Flags

- Same file path read three or more times in one session.
- A Grep/Glob result longer than the screen pasted straight into reasoning.
- Reading entire directories "for context" before knowing what you need.

## Cross-references

- RTK owns shell-command output. Bound all other output at its source.
