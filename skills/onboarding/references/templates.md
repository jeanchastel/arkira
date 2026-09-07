# Onboarding Guide: [Project Name]

## Overview
[2-3 sentences: what this project does and who it serves]

## Tech Stack
<!-- Example for a Next.js project: replace with detected stack -->
| Layer | Technology | Version |
|-------|-----------|---------|
| Language | TypeScript | 5.x |
| Framework | Next.js | 14.x |
| Database | PostgreSQL | 16 |
| ORM | Prisma | 5.x |
| Testing | Jest + Playwright | - |

## Architecture
[Diagram or description of how components connect]

## Key Entry Points
<!-- Example for a Next.js project: replace with detected paths -->
- **API routes**: `src/app/api/`, Next.js route handlers
- **UI pages**: `src/app/(dashboard)/`, authenticated pages
- **Database**: `prisma/schema.prisma`, data model source of truth
- **Config**: `next.config.ts`, build and runtime config

## Directory Map
[Top-level directory → purpose mapping]

## Request Lifecycle
[Trace one API request from entry to response]

## Conventions
- [File naming pattern]
- [Error handling approach]
- [Testing patterns]
- [Git workflow]

## Common Tasks
<!-- Example for a Node.js project: replace with detected commands -->
- **Run dev server**: `pnpm dev` (detect the repo's manager from its lockfile first)
- **Run tests**: `pnpm test`
- **Run linter**: `pnpm lint`
- **Database migrations**: `pnpm dlx prisma migrate dev`
- **Build for production**: `pnpm build`

## Where to Look
<!-- Example for a Next.js project: replace with detected paths -->
| I want to... | Look at... |
|--------------|-----------|
| Add an API endpoint | `src/app/api/` |
| Add a UI page | `src/app/(dashboard)/` |
| Add a database table | `prisma/schema.prisma` |
| Add a test | `tests/` matching the source path |
| Change build config | `next.config.ts` |

#### Output 2: Starter CLAUDE.md

Generate or update a project-specific CLAUDE.md based on detected conventions. If `CLAUDE.md` already exists, read it first and enhance it. Preserve existing project-specific instructions and clearly call out what was added or changed.

```markdown
# Project Instructions

## Tech Stack
[Detected stack summary]

## Code Style
- [Detected naming conventions]
- [Detected patterns to follow]

## Testing
- Run tests: `[detected test command]`
- Test pattern: [detected test file convention]
- Coverage: [if configured, the coverage command]

## Build & Run
- Dev: `[detected dev command]`
- Build: `[detected build command]`
- Lint: `[detected lint command]`

## Project Structure
[Key directory → purpose map]

## Conventions
- [Commit style if detectable]
- [PR workflow if detectable]
- [Error handling patterns]
```

## Best Practices

1. **Don't read everything**: reconnaissance should use Glob and Grep, not Read on every file. Read selectively only for ambiguous signals.
2. **Verify, don't guess**: if a framework is detected from config but the actual code uses something different, trust the code.
3. **Respect existing CLAUDE.md**: if one already exists, enhance it rather than replacing it. Call out what's new vs existing.
4. **Stay concise**: the onboarding guide should be scannable in 2 minutes. Details belong in the code, not the guide.
5. **Flag unknowns**: if a convention can't be confidently detected, say so rather than guessing. "Could not determine test runner" is better than a wrong answer.

## Anti-Patterns to Avoid

- Generating a CLAUDE.md that's longer than 100 lines: keep it focused
- Listing every dependency: highlight only the ones that shape how you write code
- Describing obvious directory names: `src/` doesn't need an explanation
- Copying the README: the onboarding guide adds structural insight the README lacks
