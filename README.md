# 📊 onchain-sheets 📊

Excel in Solidity. A `Sheet` contract where every cell holds either a literal `int256` or a formula
that references other cells. The cell linking is the whole point: writes maintain a dependency graph,
reads walk it.

Built on [`tom2o17/2o17-solidity-pnpm-template`](https://github.com/tom2o17/2o17-solidity-pnpm-template)
— pnpm for deps, no git submodules.

## Usage

```
pnpm i          # install external contracts
pnpm build      # or: forge build
pnpm test       # or: forge test
pnpm lint:check # prettier check
pnpm lint:fix-all
```

Two changes to the template's tooling were needed to get a green local run:

- A `pnpm-workspace.yaml` with an `onlyBuiltDependencies` entry for `frax-standard-solidity`. pnpm
  10+ refuses to run build scripts for git-hosted packages without an explicit allowlist, so
  `pnpm i` fails on the template as-is.
- The CI workflow's pnpm pin moved from `8.11.0` to `10.28.2`. The committed `pnpm-lock.yaml` is
  already `lockfileVersion: '9.0'`, which pnpm 8 cannot read.

The template's CI badge has been removed rather than left pointing at a workflow that has never run:
GitHub disables Actions on newly forked repositories until the owner re-enables them in the web UI,
and that toggle is not reachable over the API. Everything below was verified locally instead
(`forge build`, `forge test`, `pnpm lint:check`).

---

## Cell encoding

A cell id is a `uint32` with the column in the high 16 bits and the row in the low 16 bits:

```
uint32 id = (uint32(col) << 16) | uint32(row);
```

`encode(uint16,uint16)` and `decode(uint32)` are public pure helpers, and there is a fuzz test
asserting the round-trip over the entire `uint16 × uint16` space.

Why this and not `keccak256(col, row)` or a 2D mapping: a single `uint32` key means one mapping slot
per cell, cheap equality comparison during graph traversal, and dependency lists that pack four
references per storage word. The 16/16 split is arbitrary but symmetric — 65,536 columns is far more
than any real sheet needs, and the sheet's *actual* dimensions are narrower anyway.

The addressable region is clamped by two immutables set in the constructor, `cols` and `rows`.
Coordinates at or beyond either bound revert with `CellOutOfBounds(col, row)` — at *write* time for
formula references, and at read time for direct lookups. This is what makes "out of range" a real
condition rather than a no-op, since every `uint32` is otherwise a syntactically valid id.

## Formula model

```solidity
enum CellKind { EMPTY, LITERAL, FORMULA }
enum Op       { ADD, SUB, MUL, DIV, SUM }

struct Operand { bool isRef; uint32 cell; int256 value; }
```

- `setLiteral(col, row, value)` — store an `int256`.
- `setFormula(col, row, op, a, b)` — binary `ADD`/`SUB`/`MUL`/`DIV`. Each operand is independently
  either a cell reference or an inline constant, so `A0 * 3`, `A0 - B1` and `10 / 2` are all
  expressible. `Op.SUM` is rejected here.
- `setSum(col, row, col0, row0, col1, row1)` — fold the rectangular range spanned by two corners.
- `clearCell(col, row)` — back to `EMPTY`.

There is deliberately no expression tree. A cell holds *one* operation over at most two operands;
deeper expressions are built by chaining cells, which is exactly how a spreadsheet works and keeps
the on-chain representation a fixed-size struct. `(A0 + B0) * 2` is two cells, not one.

Everything is `int256`. No floats, no fixed-point scaling — `DIV` is Solidity integer division and
truncates toward zero (`-7 / 2 == -3`, tested). If you want two decimal places, store cents.

## Evaluation strategy

**Lazy recursive read.** Nothing is cached. `getValue` evaluates a cell on demand, recursing into
each referenced cell.

The alternative was eager recompute on write: keep a *reverse* dependency index and, on every write,
walk forward and rewrite every downstream cached value.

| | lazy read (chosen) | eager write |
|---|---|---|
| write cost | O(direct refs) — one SSTORE per edge | O(size of the transitive dependent set), unbounded by anything the writer controls |
| read cost | O(subgraph below the cell), and it's a `view` call so usually free off-chain | O(1) SLOAD |
| on-chain consumer | pays the full traversal every call | pays one SLOAD |
| shared subgraphs | re-evaluated once per path — a diamond evaluates the shared root twice | evaluated once |

Lazy wins here because writes are the thing users actually pay for, and a single literal edit at the
root of a wide graph would otherwise cost the writer for everyone else's cells. It also means no
reverse index to keep consistent. The cost is that reads are unbounded-ish and, for a sheet consumed
by another contract, potentially expensive.

**Gas / depth implications.** Because there is no memoisation, a cell referenced from N paths is
evaluated N times, so a deep diamond-shaped graph is exponential in the worst case, not linear.
Recursion is capped by `MAX_DEPTH = 64` edges; exceeding it reverts with `MaxDepthExceeded(cell)`
rather than blowing the call stack. The depth guard bounds chain length, not total work — a
64-deep graph that is also wide can still exhaust the block gas limit on read. For anything
serious the read should be done off-chain via `eth_call`, where the gas ceiling is a node config.

## Cycle detection

Mandatory and enforced **at write time**, so a stored graph is acyclic by construction and reads can
recurse without fear.

Each cell keeps its outgoing edges in `mapping(uint32 => uint32[]) _deps`. After a write installs the
new cell and its edges, `_assertNoCycle(root)` runs an *iterative* DFS (explicit `uint32[]` memory
stack — no recursion, so the checker itself cannot blow the stack) from the root's dependencies. If
the traversal ever reaches `root`, the write reverts with `CycleDetected(uint32 cell)`, which rolls
back the tentative write along with it — there is a test asserting the target cell's prior contents
survive a rejected write.

Visited-node bookkeeping uses a monotonically increasing epoch counter (`_visitMark[node] == epoch`)
so nothing has to be cleared between calls. Traversal is capped at `MAX_TRAVERSAL_NODES = 512`
visited nodes and stack entries; beyond that the write reverts with `GraphTooLarge()` rather than
running out of gas ambiguously.

Because the invariant is maintained inductively on every write, checking reachability from the single
cell being written is sufficient — the rest of the graph was already acyclic.

`SUM` ranges register *every* cell in the range as a dependency, including empty ones. That matters:
if `D0 = SUM(A0:B1)` and `B1` is empty, a later `B1 = D0 + 1` still has to be rejected, and it is
(tested). Self-containing ranges (`A0 = SUM(A0:B1)`) are caught by the same mechanism.

Tested: direct self-reference, 2-hop, 3-hop, 4-hop, through a SUM range, a self-containing range,
plus a negative case asserting a diamond (shared subgraph, no cycle) is *allowed*.

## Defined error behaviour

| Condition | Behaviour |
|---|---|
| Read an empty cell, or a formula that references one | revert `EmptyCellReference(uint32 cell)` |
| Empty cell *inside a SUM range* | contributes `0` — see below |
| `DIV` with a zero divisor (constant or evaluated) | revert `DivisionByZero(uint32 cell)` |
| Reference or target outside `cols`/`rows` | revert `CellOutOfBounds(uint16 col, uint16 row)` |
| Inverted SUM range | revert `InvalidRange(uint32 start, uint32 end)` |
| SUM range over `MAX_RANGE_CELLS` (256) | revert `RangeTooLarge(uint256 size)` |
| Evaluation deeper than `MAX_DEPTH` (64) | revert `MaxDepthExceeded(uint32 cell)` |
| Cycle | revert `CycleDetected(uint32 cell)` |
| Cycle check exceeding `MAX_TRAVERSAL_NODES` | revert `GraphTooLarge()` |
| Non-editor write | revert `NotEditor(address caller)` |
| `int256` overflow in ADD/SUB/MUL | standard `Panic(0x11)` from checked arithmetic |

**On empty cells.** The split is deliberate. A *direct* reference to an empty cell is a mistake —
`B0 = A0 + 1` where `A0` was never written is almost certainly a typo or a deleted input, and
silently yielding `1` hides it. So that reverts. A *range* containing empty cells is the normal case:
`SUM(A0:A99)` over a partially filled column is the single most common spreadsheet formula there is,
and requiring the whole range to be populated would make ranges useless. That's the one place
empty-as-zero is correct, and it is documented on the function and tested both ways.

Arithmetic overflow is left as the native `Panic(0x11)` rather than wrapped in a custom error — it is
not a spreadsheet-semantics condition, it's the EVM telling you `int256` ran out, and the standard
panic is more legible to tooling than a bespoke selector. It is still explicitly tested.

## Access control

**Owner-gated writes, permissionless reads.** The owner may write any cell and may grant or revoke an
editor allowlist via `setEditor(address, bool)`; editors may write cells but not manage other editors.

Why not open writes: with an open sheet anyone can overwrite your inputs, and worse, anyone can grief
the graph — plant a 64-deep chain or a 256-cell SUM under a cell you depend on and make your reads
unaffordable, or delete a cell out from under a formula and turn a working read into a revert. The
dependency graph is shared mutable state with no per-cell ownership story, so a document-with-an-
author model is the honest one. Reads stay open because that's the point of putting it on chain.

## Known limitations

- **No caching, no memoisation.** Repeated sub-expressions are re-evaluated per path. A cell read
  from many paths gets recomputed many times.
- **Depth cap of 64 edges.** Chains longer than that are unreadable, and there is no way to raise it
  short of redeploying. It's a constant, not a parameter — deliberately, since a per-sheet knob would
  just let the owner set it high enough to brick reads.
- **Read gas is unbounded in practice.** The depth guard bounds *chain length*, not *total work*.
  A wide graph within the depth limit can still exceed the block gas limit. Reads from another
  contract are a real risk; off-chain `eth_call` is the intended consumer.
- **`SUM` writes are expensive.** A 256-cell range writes 256 dependency slots. That is roughly
  7.8M gas in the test suite — near a block. The cap keeps it bounded, not cheap.
- **Integers only.** No floats, no fixed-point convention imposed. Scale your own units.
- **Two operands per formula.** No parentheses, no n-ary expressions, no functions beyond `SUM`.
  No `AVG`, `MIN`, `MAX`, `IF`, no relative/absolute reference distinction, no row/column insertion
  (which would require rewriting every reference).
- **Clearing a cell breaks its dependents** rather than being blocked or cascading. Dependents revert
  with `EmptyCellReference` on read until repaired. Tested, but it is a sharp edge.
- **No reverse dependency index**, so there is no on-chain way to ask "what depends on this cell"
  before you change or clear it.
- **Not audited, not deployed anywhere.** This is an exercise.

## Tests

41 tests, all asserting real behaviour. Every `expectRevert` pins a selector and its arguments;
there are no bare `expectRevert()` calls.

The suite was checked against six mutations of the contract (cycle check removed, `ADD` turned into
`SUB`, SUM's empty-skip removed, the editor check removed, the depth guard removed, the div-by-zero
check removed). Every one of them turned the suite red, so the tests are not vacuous.

One harness gotcha worth recording: `vm.expectRevert(abi.encodeWithSelector(E.selector, sheet.encode(a, b)))`
silently *consumes* the cheatcode, because `sheet.encode` is an external call and it is the next call
the cheatcode sees. The tests use a local pure `_enc` mirror instead. This is exactly the failure mode
that produces tests which pass while asserting nothing.
