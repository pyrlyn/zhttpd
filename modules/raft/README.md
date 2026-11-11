# zhttpd-raft

Optional consensus companion for zhttpd. See [configuration, API and failure
semantics](../../docs/raft.md) and [local demo](../../examples/raft/make-local.py).

- `node.go`: Raft lifecycle, TLS transport, authenticated API and membership.
- `state.go`: deterministic configuration/metrics FSM, revisions and snapshots.
- `export.go`: worker metric batches and atomic committed-state exports.
- `config.go`: local identity, paths, transport and membership validation.

Build with `zig build raft` from the repository root. Run tests with
`go -C modules/raft test -race ./...` and `zig build test-raft-e2e`.

Dependencies are pinned in go.mod/go.sum. HashiCorp Raft and raft-boltdb/v2 are
licensed under MPL-2.0; bbolt uses the MIT license. They are consumed unmodified
as Go modules. Source and license texts:

- https://github.com/hashicorp/raft/tree/v1.8.0
- https://github.com/hashicorp/raft-boltdb/tree/v2.4.2
- https://github.com/etcd-io/bbolt/tree/v1.4.1

The normal Zig server build does not depend on Go. Only the opt-in companion
requires the pinned Go toolchain.
