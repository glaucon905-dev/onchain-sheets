// SPDX-License-Identifier: ISC
pragma solidity ^0.8.20;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// @title Sheet
/// @notice A minimal on-chain spreadsheet. Cells are addressed by (column, row) and hold either a
///         literal `int256` or a formula that references other cells. Formula cells form a directed
///         graph; the contract keeps that graph acyclic by rejecting any write that would close a
///         cycle, so reads can safely recurse.
/// @dev Cell identifiers are packed as `uint32 id = (uint32(col) << 16) | uint32(row)`, i.e. the
///      column lives in the high 16 bits and the row in the low 16 bits. The addressable space is
///      further clamped by the immutable `cols`/`rows` dimensions chosen at construction.
contract Sheet is Ownable {
    /*//////////////////////////////////////////////////////////////
                                  TYPES
    //////////////////////////////////////////////////////////////*/

    /// @notice What a cell currently holds.
    enum CellKind {
        EMPTY,
        LITERAL,
        FORMULA
    }

    /// @notice Supported formula operations.
    /// @dev ADD/SUB/MUL/DIV are binary over two operands. SUM ignores the operands and instead
    ///      folds the rectangular range [rangeStart, rangeEnd].
    enum Op {
        ADD,
        SUB,
        MUL,
        DIV,
        SUM
    }

    /// @notice A binary-formula operand: either a reference to another cell or an inline constant.
    /// @param isRef True when the operand is a cell reference, false when it is a constant.
    /// @param cell Packed cell id, only meaningful when `isRef` is true.
    /// @param value Inline constant, only meaningful when `isRef` is false.
    struct Operand {
        bool isRef;
        uint32 cell;
        int256 value;
    }

    /// @notice Full on-chain representation of a cell.
    /// @param kind EMPTY, LITERAL or FORMULA.
    /// @param op Operation, meaningful only when `kind == FORMULA`.
    /// @param aIsRef Whether operand A is a reference.
    /// @param bIsRef Whether operand B is a reference.
    /// @param aRef Packed id for operand A when it is a reference.
    /// @param bRef Packed id for operand B when it is a reference.
    /// @param rangeStart Top-left packed id of a SUM range.
    /// @param rangeEnd Bottom-right packed id of a SUM range.
    /// @param literal Value when `kind == LITERAL`.
    /// @param aVal Constant for operand A when it is not a reference.
    /// @param bVal Constant for operand B when it is not a reference.
    struct Cell {
        CellKind kind;
        Op op;
        bool aIsRef;
        bool bIsRef;
        uint32 aRef;
        uint32 bRef;
        uint32 rangeStart;
        uint32 rangeEnd;
        int256 literal;
        int256 aVal;
        int256 bVal;
    }

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when a write would make `cell` transitively depend on itself.
    error CycleDetected(uint32 cell);
    /// @notice Thrown when a coordinate falls outside the sheet dimensions.
    error CellOutOfBounds(uint16 col, uint16 row);
    /// @notice Thrown when a formula dereferences a cell that holds nothing.
    error EmptyCellReference(uint32 cell);
    /// @notice Thrown when a DIV formula's divisor evaluates to zero.
    error DivisionByZero(uint32 cell);
    /// @notice Thrown when evaluation recursion exceeds `MAX_DEPTH`.
    error MaxDepthExceeded(uint32 cell);
    /// @notice Thrown when a SUM range is inverted (end before start on either axis).
    error InvalidRange(uint32 start, uint32 end);
    /// @notice Thrown when a SUM range covers more than `MAX_RANGE_CELLS` cells.
    error RangeTooLarge(uint256 size);
    /// @notice Thrown when the cycle check would have to traverse more than `MAX_TRAVERSAL_NODES`.
    error GraphTooLarge();
    /// @notice Thrown when a non-owner, non-editor attempts a write.
    error NotEditor(address caller);
    /// @notice Thrown when the sheet is constructed with a zero dimension.
    error ZeroDimension();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted whenever a cell's contents change (including clears).
    event CellUpdated(uint32 indexed cell, CellKind kind);
    /// @notice Emitted when an address gains or loses write access.
    event EditorSet(address indexed editor, bool allowed);

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Maximum evaluation recursion depth. Reads deeper than this revert.
    uint256 public constant MAX_DEPTH = 64;
    /// @notice Maximum number of cells a single SUM range may cover.
    uint256 public constant MAX_RANGE_CELLS = 256;
    /// @notice Maximum number of nodes the write-time cycle check will visit.
    uint256 public constant MAX_TRAVERSAL_NODES = 512;

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Number of columns in the sheet (columns are indexed `0 .. cols - 1`).
    uint16 public immutable cols;
    /// @notice Number of rows in the sheet (rows are indexed `0 .. rows - 1`).
    uint16 public immutable rows;

    /// @notice Addresses allowed to write cells alongside the owner.
    mapping(address => bool) public isEditor;

    mapping(uint32 => Cell) private _cells;
    mapping(uint32 => uint32[]) private _deps;
    mapping(uint32 => uint256) private _visitMark;
    uint256 private _visitEpoch;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploy a sheet of fixed dimensions owned by `owner_`.
    /// @param cols_ Number of columns, must be non-zero.
    /// @param rows_ Number of rows, must be non-zero.
    /// @param owner_ Initial owner; the only address that may manage editors.
    constructor(uint16 cols_, uint16 rows_, address owner_) Ownable(owner_) {
        if (cols_ == 0 || rows_ == 0) revert ZeroDimension();
        cols = cols_;
        rows = rows_;
    }

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Writes are gated to the owner plus an explicit editor allowlist.
    modifier onlyEditor() {
        if (msg.sender != owner() && !isEditor[msg.sender]) revert NotEditor(msg.sender);
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                ENCODING
    //////////////////////////////////////////////////////////////*/

    /// @notice Pack a coordinate pair into a cell id.
    /// @param col Column index.
    /// @param row Row index.
    /// @return id `(col << 16) | row`.
    function encode(uint16 col, uint16 row) public pure returns (uint32 id) {
        id = (uint32(col) << 16) | uint32(row);
    }

    /// @notice Unpack a cell id back into its coordinate pair.
    /// @param id Packed cell id.
    /// @return col Column index.
    /// @return row Row index.
    function decode(uint32 id) public pure returns (uint16 col, uint16 row) {
        // casting to 'uint16' is safe because the id layout defines the high 16 bits as the column
        // forge-lint: disable-next-line(unsafe-typecast)
        col = uint16(id >> 16);
        // casting to 'uint16' is safe because the id layout defines the low 16 bits as the row
        // forge-lint: disable-next-line(unsafe-typecast)
        row = uint16(id);
    }

    /*//////////////////////////////////////////////////////////////
                              ADMIN / ACCESS
    //////////////////////////////////////////////////////////////*/

    /// @notice Grant or revoke write access for `editor`.
    /// @param editor Address whose access is being changed.
    /// @param allowed True to grant, false to revoke.
    function setEditor(address editor, bool allowed) external onlyOwner {
        isEditor[editor] = allowed;
        emit EditorSet(editor, allowed);
    }

    /*//////////////////////////////////////////////////////////////
                                 WRITES
    //////////////////////////////////////////////////////////////*/

    /// @notice Store a literal value in a cell, replacing whatever was there.
    /// @param col Column index of the target cell.
    /// @param row Row index of the target cell.
    /// @param value Value to store.
    function setLiteral(uint16 col, uint16 row, int256 value) external onlyEditor {
        uint32 id = _boundedId(col, row);
        _reset(id);

        Cell storage c = _cells[id];
        c.kind = CellKind.LITERAL;
        c.literal = value;

        emit CellUpdated(id, CellKind.LITERAL);
    }

    /// @notice Store a binary formula (`ADD`, `SUB`, `MUL` or `DIV`) in a cell.
    /// @dev Reverts with {CycleDetected} if the resulting dependency graph would contain a cycle
    ///      reachable from this cell. `SUM` is rejected here; use {setSum}.
    /// @param col Column index of the target cell.
    /// @param row Row index of the target cell.
    /// @param op Operation to apply; must not be `Op.SUM`.
    /// @param a Left operand.
    /// @param b Right operand.
    function setFormula(uint16 col, uint16 row, Op op, Operand calldata a, Operand calldata b) external onlyEditor {
        require(op != Op.SUM, "Sheet: use setSum");
        uint32 id = _boundedId(col, row);
        _reset(id);

        Cell storage c = _cells[id];
        c.kind = CellKind.FORMULA;
        c.op = op;
        c.aIsRef = a.isRef;
        c.bIsRef = b.isRef;

        if (a.isRef) {
            _requireInBounds(a.cell);
            c.aRef = a.cell;
            _deps[id].push(a.cell);
        } else {
            c.aVal = a.value;
        }

        if (b.isRef) {
            _requireInBounds(b.cell);
            c.bRef = b.cell;
            _deps[id].push(b.cell);
        } else {
            c.bVal = b.value;
        }

        _assertNoCycle(id);
        emit CellUpdated(id, CellKind.FORMULA);
    }

    /// @notice Store a `SUM` over the rectangular range spanned by two corners.
    /// @dev Every cell in the range becomes a dependency, empty or not, so that a later write into
    ///      the range is still cycle-checked. Reverts with {CycleDetected} on a cycle.
    /// @param col Column index of the target cell.
    /// @param row Row index of the target cell.
    /// @param col0 Column index of the top-left corner of the range.
    /// @param row0 Row index of the top-left corner of the range.
    /// @param col1 Column index of the bottom-right corner of the range.
    /// @param row1 Row index of the bottom-right corner of the range.
    function setSum(uint16 col, uint16 row, uint16 col0, uint16 row0, uint16 col1, uint16 row1) external onlyEditor {
        uint32 id = _boundedId(col, row);
        uint32 start = _boundedId(col0, row0);
        uint32 end = _boundedId(col1, row1);
        if (col1 < col0 || row1 < row0) revert InvalidRange(start, end);

        uint256 size = (uint256(col1 - col0) + 1) * (uint256(row1 - row0) + 1);
        if (size > MAX_RANGE_CELLS) revert RangeTooLarge(size);

        _reset(id);

        Cell storage c = _cells[id];
        c.kind = CellKind.FORMULA;
        c.op = Op.SUM;
        c.rangeStart = start;
        c.rangeEnd = end;

        uint32[] storage d = _deps[id];
        for (uint16 cc = col0; cc <= col1; ++cc) {
            for (uint16 rr = row0; rr <= row1; ++rr) {
                d.push(encode(cc, rr));
            }
        }

        _assertNoCycle(id);
        emit CellUpdated(id, CellKind.FORMULA);
    }

    /// @notice Empty a cell.
    /// @dev Dependents are not rewritten; they will revert with {EmptyCellReference} on read unless
    ///      they only touch the cell through a `SUM` range, where empty reads as zero.
    /// @param col Column index of the target cell.
    /// @param row Row index of the target cell.
    function clearCell(uint16 col, uint16 row) external onlyEditor {
        uint32 id = _boundedId(col, row);
        _reset(id);
        emit CellUpdated(id, CellKind.EMPTY);
    }

    /*//////////////////////////////////////////////////////////////
                                  READS
    //////////////////////////////////////////////////////////////*/

    /// @notice Evaluate a cell, recursing through any formulas it references.
    /// @param col Column index.
    /// @param row Row index.
    /// @return value The evaluated value.
    function getValue(uint16 col, uint16 row) external view returns (int256 value) {
        value = _eval(_boundedId(col, row), 0);
    }

    /// @notice Evaluate a cell by packed id.
    /// @param id Packed cell id.
    /// @return value The evaluated value.
    function getValueById(uint32 id) external view returns (int256 value) {
        _requireInBounds(id);
        value = _eval(id, 0);
    }

    /// @notice Read a cell's raw stored contents without evaluating it.
    /// @param col Column index.
    /// @param row Row index.
    /// @return cell The stored {Cell} struct.
    function getCell(uint16 col, uint16 row) external view returns (Cell memory cell) {
        cell = _cells[_boundedId(col, row)];
    }

    /// @notice List the cells a given cell directly depends on.
    /// @param col Column index.
    /// @param row Row index.
    /// @return deps Packed ids of direct dependencies, in write order.
    function dependenciesOf(uint16 col, uint16 row) external view returns (uint32[] memory deps) {
        deps = _deps[_boundedId(col, row)];
    }

    /// @notice Whether a cell currently holds nothing.
    /// @param col Column index.
    /// @param row Row index.
    /// @return empty True when the cell is `EMPTY`.
    function isEmpty(uint16 col, uint16 row) external view returns (bool empty) {
        empty = _cells[_boundedId(col, row)].kind == CellKind.EMPTY;
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNALS
    //////////////////////////////////////////////////////////////*/

    /// @dev Bounds-check a coordinate pair and return its packed id.
    function _boundedId(uint16 col, uint16 row) private view returns (uint32 id) {
        if (col >= cols || row >= rows) revert CellOutOfBounds(col, row);
        id = encode(col, row);
    }

    /// @dev Bounds-check an already-packed id.
    function _requireInBounds(uint32 id) private view {
        (uint16 col, uint16 row) = decode(id);
        if (col >= cols || row >= rows) revert CellOutOfBounds(col, row);
    }

    /// @dev Wipe a cell's contents and its outgoing dependency edges.
    function _reset(uint32 id) private {
        delete _cells[id];
        delete _deps[id];
    }

    /// @dev Iterative reachability search: reverts if `root` is reachable from any of its own
    ///      dependencies. Runs after the write, so a revert rolls the write back.
    function _assertNoCycle(uint32 root) private {
        uint256 epoch = ++_visitEpoch;
        uint32[] memory stack = new uint32[](MAX_TRAVERSAL_NODES);
        uint256 sp;
        uint256 visited;

        uint32[] storage rootDeps = _deps[root];
        uint256 rootDepCount = rootDeps.length;
        for (uint256 i; i < rootDepCount; ++i) {
            if (sp == MAX_TRAVERSAL_NODES) revert GraphTooLarge();
            stack[sp++] = rootDeps[i];
        }

        while (sp != 0) {
            uint32 node = stack[--sp];
            if (node == root) revert CycleDetected(root);
            if (_visitMark[node] == epoch) continue;
            _visitMark[node] = epoch;
            if (++visited > MAX_TRAVERSAL_NODES) revert GraphTooLarge();

            uint32[] storage nodeDeps = _deps[node];
            uint256 nodeDepCount = nodeDeps.length;
            for (uint256 i; i < nodeDepCount; ++i) {
                if (sp == MAX_TRAVERSAL_NODES) revert GraphTooLarge();
                stack[sp++] = nodeDeps[i];
            }
        }
    }

    /// @dev Lazily evaluate `id`. `depth` counts edges already traversed from the entry cell.
    function _eval(uint32 id, uint256 depth) private view returns (int256) {
        if (depth > MAX_DEPTH) revert MaxDepthExceeded(id);

        Cell storage c = _cells[id];
        CellKind kind = c.kind;

        if (kind == CellKind.EMPTY) revert EmptyCellReference(id);
        if (kind == CellKind.LITERAL) return c.literal;

        Op op = c.op;
        if (op == Op.SUM) return _evalSum(c, depth);

        int256 a = c.aIsRef ? _eval(c.aRef, depth + 1) : c.aVal;
        int256 b = c.bIsRef ? _eval(c.bRef, depth + 1) : c.bVal;

        if (op == Op.ADD) return a + b;
        if (op == Op.SUB) return a - b;
        if (op == Op.MUL) return a * b;
        if (b == 0) revert DivisionByZero(id);
        return a / b;
    }

    /// @dev Fold a SUM range. Empty cells inside a range contribute zero rather than reverting.
    function _evalSum(Cell storage c, uint256 depth) private view returns (int256 total) {
        (uint16 col0, uint16 row0) = decode(c.rangeStart);
        (uint16 col1, uint16 row1) = decode(c.rangeEnd);

        for (uint16 cc = col0; cc <= col1; ++cc) {
            for (uint16 rr = row0; rr <= row1; ++rr) {
                uint32 memberId = encode(cc, rr);
                if (_cells[memberId].kind == CellKind.EMPTY) continue;
                total += _eval(memberId, depth + 1);
            }
        }
    }
}
