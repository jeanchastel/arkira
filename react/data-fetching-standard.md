# React Data Fetching Standard

Status: canonical. Synced to product repos via `/arkira-sync`.

## Switch

`react_data_fetching` in `ai-engineering/bootstrap/switches.json`. Default on.

## Waterfalls

- Run independent async operations concurrently with `Promise.all()`
  (`async-parallel`).
- Start partially dependent work as soon as its inputs exist. Model the dependency
  graph with early promises or an approved dependency-aware combinator rather than
  serializing unrelated work (`async-dependencies`).
- Defer an `await` until the branch that needs its result. Check cheap synchronous
  guards before remote flags or other async conditions, unless ordering or side
  effects require otherwise (`async-defer-await`,
  `async-cheap-condition-before-await`).
- In Route Handlers and Server Actions, start independent work before awaiting
  authentication or another prerequisite, then join it at the response boundary
  (`async-api-routes`). Existing authorization requirements remain governed by
  `security/auth-standard.md`.
- Put slow, non-layout-critical subtrees behind stable Suspense boundaries so the
  shell can stream. Do not use Suspense where layout, above-the-fold SEO content,
  or a trivial query makes the fallback harmful (`async-suspense-boundaries`).

## RSC Parallel Fetch

- Split independent fetching into sibling Server Components, or pass independent
  children into a layout, so a parent fetch does not block the rest of the tree
  (`server-parallel-fetching`).
- For collections with nested dependencies, chain each item's dependent fetch
  inside that item's promise. One slow item must not hold every other item at the
  same stage (`server-parallel-nested-fetching`).
- Schedule logging, analytics, notifications, cache invalidation, and cleanup with
  Next.js `after()` when they must not delay the response. Use it only when the
  work may safely run after failures and redirects (`server-after-nonblocking`).

## RSC Caching

- Use `React.cache()` for per-request deduplication of authentication, database,
  filesystem, and other non-`fetch` work. Prefer primitive arguments because cache
  hits use shallow identity (`server-cache-react`).
- Use a bounded, expiring LRU only for deliberately shared cross-request data.
  Choose an external cache when execution instances cannot share memory
  (`server-cache-lru`).
- Hoist immutable, request-independent I/O to module initialization. Keep
  request-varying, mutable, oversized, and sensitive data out of module-level
  static caches (`server-hoist-static-io`).

## RSC Isolation and Serialization

- **Correctness:** never store request- or user-scoped mutable state at module
  scope. Server module state is process-wide and can leak across concurrent
  requests. Pass request data through the render tree or a request-scoped
  mechanism (`server-no-shared-module-state`).
- Cross-request caches are an explicit isolation boundary: keys, lifetime, and
  tenant scope must prevent one request from observing another request's data
  (`server-no-shared-module-state`, `server-cache-lru`).
- Pass only fields the Client Component uses across the RSC boundary. Serialized
  props add directly to HTML and RSC payload weight (`server-serialization`).
  Secret exposure remains governed by
  `security/environment-variable-standard.md`.

## Do / Do not

Do:

- start independent work together and preserve only real dependencies
- choose cache scope explicitly: request, process, or external
- keep request identity and mutable request data local
- send minimal client-facing payloads

Do not:

- serialize independent awaits into a waterfall
- use module-level mutable variables as request context
- treat `React.cache()` as a cross-request cache
- pass whole server records to a client that needs a few fields

## Pre-Ship Checklist

- independent awaits and RSC subtrees run in parallel
- deferred work does not block the response
- cache scope, keys, TTL, and tenant isolation reviewed
- no request-scoped mutable module state
- RSC-to-client props contain only consumed fields
- Suspense fallbacks preserve layout and critical content
