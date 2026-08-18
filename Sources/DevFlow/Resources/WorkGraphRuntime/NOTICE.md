# WorkGraph Runtime Notices

This directory is a DevFlow-owned, versioned local runtime. It does not invoke
or depend on a user's CodeGraph, Cursor, DevEco, or system Node installation.

- Node.js v22.18.0, MIT. The App still bundles `node-arm64` / `node-x86_64`
  extracted from the official Node.js macOS distributions. Those executables
  exceed GitHub's 100 MB file limit, so they are not stored in git. Fetch them
  with `scripts/fetch-workgraph-node.sh` before building or testing.
  Source: https://nodejs.org/dist/v22.18.0/
- web-tree-sitter v0.25.10, MIT. License: `licenses/web-tree-sitter-LICENSE`.
- tree-sitter-wasms v0.1.13, Unlicense. License:
  `licenses/tree-sitter-wasms-LICENSE`.
- tree-sitter-arkts v0.2.0, MIT. License:
  `licenses/tree-sitter-arkts-LICENSE`.

The parser is WorkGraph-specific and its NDJSON protocol is defined by
`WorkGraphParserProtocol` in DevFlow. The helper only receives repository-
relative paths and source text already read by DevFlow.
