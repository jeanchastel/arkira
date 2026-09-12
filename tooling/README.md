# Tooling Standards

Toolchain and build standards that are not vendor-specific.

- [Package Manager (pnpm)](./package-manager-standard.md) : pnpm is the only manager for new
  Arkira-guided JavaScript work; declared npm and Yarn repositories keep their manager and version.
- [TypeScript LSP](./lsp-standard.md) : TypeScript language-server setup and
  symbol-navigation preference.
- [Third-Party Skills](./third-party-skills-standard.md) : allowed sources,
  pinning, hook and script review, and review cadence for adopted marketplace
  skills.
- [Test Suite (Vitest + RTL)](./test-suite-standard.md) : never serialize a suite; set
  `asyncUtilTimeout` explicitly; register cleanup centrally; never let a fixed sleep guard a
  negative assertion. Focused runs are version-aware and manager-routed.
- [Suggested Tools](./suggested-tools.md) : optional, never-installed tools that
  pair with the plugin (RTK, token-optimizer, Semble, codebase-memory-mcp), each license-noted.
