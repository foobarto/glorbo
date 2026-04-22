# Knowledge graph

Machine-generated navigational map of the codebase produced by
[graphify](https://graphify.net). Consult `GRAPH_REPORT.md` before
reading source files to answer "where is X?" / "what calls Y?"
questions — it's ~75× cheaper in tokens than grep-and-read across
200+ modules.

## What's here

- **`GRAPH_REPORT.md`** — committed summary. Community clustering,
  god nodes, surprising connections, knowledge gaps. Read this first.
- `graph.json`, `graph.html`, `cache/` — **not committed**. The JSON
  is ~3 MB (binary-ish), the HTML 2 MB, the cache rebuilds from the
  source tree. Regenerate locally if you need live queries.

## Regenerating the graph

```sh
# Scope to lib/ — including deps/ or _build/ swamps the signal
# with tree-sitter noise from Elixir stdlib and dependency code.
graphify update lib

# Output lands in `lib/graphify-out/`. Move the report:
mv lib/graphify-out/GRAPH_REPORT.md docs/knowledge-graph/
rm -rf lib/graphify-out
```

Prereqs: `uv tool install graphifyy` once. No Claude Code / editor
integration needed — the standalone CLI works fine.

## Live queries (optional)

With `lib/graphify-out/graph.json` present (i.e. you just
regenerated):

```sh
graphify query "where is proposal validation?"
graphify path  "Glorbo.Company.Router" "Glorbo.PathGrantStore"
graphify explain "Glorbo.Agent.Dispatch"
```

Each returns a small token-budgeted traversal of the graph —
designed to be pasted into a Claude Code conversation. Token cap
defaults to 2000; override with `--budget N`.

## Known limitations

The graph is heuristic (tree-sitter AST + statistical clustering).
Known false-positive patterns flagged in
[`docs/architecture.md` §Graph caveats](../architecture.md):

- **Generic function names collapse across modules.** `parse()`,
  `get()`, `lookup()`, `run()` appear as high-centrality nodes but
  are cross-module name collisions, not real abstractions.
- **Each `FileSpec.*Md` module is a 6-node "thin community".**
  That's the intended GEP-25 pattern (spec modules are isolated by
  contract); the graph flags them as under-connected.
- **Inferred edges (~20%) are lower-confidence.** Treat an
  `INFERRED` edge as a hint, not a fact. When it surprises you,
  open both source files and verify.

## Maintenance rhythm

The graph must be refreshed when architecture changes, or it silently
mis-advises future sessions. The 6-phase feature checklist in
[`CLAUDE.md`](../../CLAUDE.md) §"Feature development" step 6 includes
knowledge-graph refresh for any change that adds, removes, or
rewires a module.
