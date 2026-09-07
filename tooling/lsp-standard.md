# TypeScript LSP Standard

Status: canonical. Synced to product repos via `/arkira-sync`.

## Switch

`prefer_lsp_navigation` in `ai-engineering/bootstrap/switches.json`. Default on.

## Why

A language server gives symbol-precise navigation: go-to-definition,
find-all-references, and rename that follow the real symbol, not matching text. On
a uniform TypeScript stack this is the highest-value navigation investment. Grep for
a common name returns thousands of hits and wastes context; the language server
returns only the references that point to the same symbol.

## Server

For the Arkira Next.js plus TypeScript stack, use the official Claude Code
`typescript-lsp` code-intelligence plugin with `typescript-language-server` and
the `typescript` package. Confirm the current recommended server against the
Claude Code code-intelligence documentation.

## Setup (per machine)

1. Install the Claude Code `typescript-lsp` code-intelligence plugin for
   TypeScript (see the Claude Code plugins documentation for the current plugin).
2. Install the language-server binary:
   - `pnpm add -g typescript typescript-language-server` (or the npm equivalent)
3. Open a TypeScript repo in Claude Code and confirm the server attaches (see
   Verification).

## Use

- Prefer symbol navigation for anything symbol-shaped: a function, type, interface,
  React component, hook, or constant. Use go-to-definition, find-references, rename,
  and symbol search.
- Use grep for text and non-symbol search: strings, comments, config keys, log
  messages.
- When grep and the server disagree on a symbol, trust the server; it disambiguates
  identically named symbols that grep cannot.

## Per Repo

- The server reads each repo's `tsconfig.json`; ensure every app and package has
  one so paths and project references resolve.
- For workspace packages, confirm project references so cross-package
  go-to-definition works.

## Verification

- Go-to-definition on an imported symbol lands on its declaration, not a re-export
  or a same-named symbol.
- Find-references on a widely used function returns real call sites, not substring
  matches.
- Rename a local symbol and confirm only true references change.

## Do Not

- rely on grep for symbol navigation when the server is available
- skip `tsconfig.json` in a package (the server cannot resolve it)
- assume LSP is automatic; it needs the plugin and the binary
