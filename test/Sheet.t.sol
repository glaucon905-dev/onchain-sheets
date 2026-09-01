// SPDX-License-Identifier: ISC
pragma solidity ^0.8.20;

import { Test, stdError } from "forge-std/Test.sol";
import { Sheet } from "../src/Sheet.sol";

contract SheetTest is Test {
    Sheet internal sheet;

    address internal owner = address(0xA11CE);
    address internal editor = address(0xED170);
    address internal stranger = address(0xBAD);

    // Column/row shorthand mirroring spreadsheet A1 notation: A = col 0, B = col 1, ...
    uint16 internal constant A = 0;
    uint16 internal constant B = 1;
    uint16 internal constant C = 2;
    uint16 internal constant D = 3;

    function setUp() public {
        vm.prank(owner);
        sheet = new Sheet(64, 128, owner);
        vm.prank(owner);
        sheet.setEditor(editor, true);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Local pure mirror of `Sheet.encode`. Must not be an external call: an external call
    ///      inside a `vm.expectRevert` argument list would consume the cheatcode.
    function _enc(uint16 col, uint16 row) internal pure returns (uint32) {
        return (uint32(col) << 16) | uint32(row);
    }

    function _ref(uint16 col, uint16 row) internal pure returns (Sheet.Operand memory) {
        return Sheet.Operand({ isRef: true, cell: _enc(col, row), value: 0 });
    }

    function _const(int256 v) internal pure returns (Sheet.Operand memory) {
        return Sheet.Operand({ isRef: false, cell: 0, value: v });
    }

    /*//////////////////////////////////////////////////////////////
                                ENCODING
    //////////////////////////////////////////////////////////////*/

    function test_Encode_PacksColumnHighRowLow() public view {
        assertEq(_enc(3, 7), (uint32(3) << 16) | uint32(7));
    }

    function testFuzz_EncodeDecodeRoundTrip(uint16 col, uint16 row) public view {
        (uint16 dCol, uint16 dRow) = sheet.decode(_enc(col, row));
        assertEq(dCol, col);
        assertEq(dRow, row);
    }

    /*//////////////////////////////////////////////////////////////
                             LITERALS + OPS
    //////////////////////////////////////////////////////////////*/

    function test_SetLiteral_StoresAndReads() public {
        vm.prank(owner);
        sheet.setLiteral(A, 0, -42);
        assertEq(sheet.getValue(A, 0), -42);
        assertFalse(sheet.isEmpty(A, 0));
    }

    function test_Add_RefPlusConstant() public {
        vm.startPrank(owner);
        sheet.setLiteral(A, 0, 10);
        sheet.setFormula(B, 0, Sheet.Op.ADD, _ref(A, 0), _const(5));
        vm.stopPrank();
        assertEq(sheet.getValue(B, 0), 15);
    }

    function test_Sub_RefMinusRef() public {
        vm.startPrank(owner);
        sheet.setLiteral(A, 0, 10);
        sheet.setLiteral(A, 1, 3);
        sheet.setFormula(B, 0, Sheet.Op.SUB, _ref(A, 0), _ref(A, 1));
        vm.stopPrank();
        assertEq(sheet.getValue(B, 0), 7);
    }

    function test_Mul_HandlesNegatives() public {
        vm.startPrank(owner);
        sheet.setLiteral(A, 0, -6);
        sheet.setFormula(B, 0, Sheet.Op.MUL, _ref(A, 0), _const(7));
        vm.stopPrank();
        assertEq(sheet.getValue(B, 0), -42);
    }

    function test_Div_TruncatesTowardZero() public {
        vm.startPrank(owner);
        sheet.setLiteral(A, 0, -7);
        sheet.setFormula(B, 0, Sheet.Op.DIV, _ref(A, 0), _const(2));
        vm.stopPrank();
        // Solidity integer division truncates toward zero: -7 / 2 == -3, not -4.
        assertEq(sheet.getValue(B, 0), -3);
    }

    function test_SetFormula_RejectsSumOpcode() public {
        vm.prank(owner);
        vm.expectRevert(bytes("Sheet: use setSum"));
        sheet.setFormula(B, 0, Sheet.Op.SUM, _const(1), _const(1));
    }

    /*//////////////////////////////////////////////////////////////
                                  SUM
    //////////////////////////////////////////////////////////////*/

    function test_Sum_OverRectangularRange() public {
        vm.startPrank(owner);
        sheet.setLiteral(A, 0, 1);
        sheet.setLiteral(A, 1, 2);
        sheet.setLiteral(B, 0, 3);
        sheet.setLiteral(B, 1, 4);
        // Cell outside the range must not be counted.
        sheet.setLiteral(C, 0, 1000);
        sheet.setSum(D, 0, A, 0, B, 1);
        vm.stopPrank();
        assertEq(sheet.getValue(D, 0), 10);
    }

    function test_Sum_TreatsEmptyCellsAsZero() public {
        vm.startPrank(owner);
        sheet.setLiteral(A, 0, 5);
        // A1 and the whole B column of the range stay empty.
        sheet.setSum(D, 0, A, 0, B, 1);
        vm.stopPrank();
        assertEq(sheet.getValue(D, 0), 5);
    }

    function test_Sum_IncludesNestedFormulaCells() public {
        vm.startPrank(owner);
        sheet.setLiteral(A, 0, 4);
        sheet.setFormula(A, 1, Sheet.Op.MUL, _ref(A, 0), _const(3)); // 12
        sheet.setSum(D, 0, A, 0, A, 1);
        vm.stopPrank();
        assertEq(sheet.getValue(D, 0), 16);
    }

    function test_Sum_RevertsOnInvertedRange() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Sheet.InvalidRange.selector, _enc(B, 5), _enc(A, 1)));
        sheet.setSum(D, 0, B, 5, A, 1);
    }

    function test_Sum_RevertsWhenRangeTooLarge() public {
        vm.prank(owner);
        // 17 x 17 = 289 cells > MAX_RANGE_CELLS (256).
        vm.expectRevert(abi.encodeWithSelector(Sheet.RangeTooLarge.selector, uint256(289)));
        sheet.setSum(D, 40, 0, 0, 16, 16);
    }

    function test_Sum_AllowsExactlyMaxRangeCells() public {
        vm.prank(owner);
        // 16 x 16 = 256 cells == MAX_RANGE_CELLS.
        sheet.setSum(D, 40, 0, 0, 15, 15);
        uint32[] memory deps = sheet.dependenciesOf(D, 40);
        assertEq(deps.length, sheet.MAX_RANGE_CELLS());
    }

    /*//////////////////////////////////////////////////////////////
                          DEPENDENCY PROPAGATION
    //////////////////////////////////////////////////////////////*/

    function test_MultiLevelChain_PropagatesRootChange() public {
        // A0 = 2, B0 = A0 * 3, C0 = B0 + 4, D0 = C0 - 1
        vm.startPrank(owner);
        sheet.setLiteral(A, 0, 2);
        sheet.setFormula(B, 0, Sheet.Op.MUL, _ref(A, 0), _const(3));
        sheet.setFormula(C, 0, Sheet.Op.ADD, _ref(B, 0), _const(4));
        sheet.setFormula(D, 0, Sheet.Op.SUB, _ref(C, 0), _const(1));
        vm.stopPrank();

        assertEq(sheet.getValue(B, 0), 6);
        assertEq(sheet.getValue(C, 0), 10);
        assertEq(sheet.getValue(D, 0), 9);

        // Change the root: every downstream cell must move with it.
        vm.prank(owner);
        sheet.setLiteral(A, 0, 5);

        assertEq(sheet.getValue(B, 0), 15);
        assertEq(sheet.getValue(C, 0), 19);
        assertEq(sheet.getValue(D, 0), 18);
    }

    function test_RewritingCellReplacesItsDependencies() public {
        vm.startPrank(owner);
        sheet.setLiteral(A, 0, 1);
        sheet.setLiteral(A, 1, 100);
        sheet.setFormula(B, 0, Sheet.Op.ADD, _ref(A, 0), _const(0));
        assertEq(sheet.dependenciesOf(B, 0).length, 1);
        assertEq(sheet.getValue(B, 0), 1);

        sheet.setFormula(B, 0, Sheet.Op.ADD, _ref(A, 1), _const(0));
        vm.stopPrank();

        uint32[] memory deps = sheet.dependenciesOf(B, 0);
        assertEq(deps.length, 1);
        assertEq(deps[0], _enc(A, 1));
        assertEq(sheet.getValue(B, 0), 100);
    }

    /*//////////////////////////////////////////////////////////////
                            CYCLE DETECTION
    //////////////////////////////////////////////////////////////*/

    function test_Cycle_DirectSelfReference() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Sheet.CycleDetected.selector, _enc(A, 0)));
        sheet.setFormula(A, 0, Sheet.Op.ADD, _ref(A, 0), _const(1));
    }

    function test_Cycle_TwoHop() public {
        // A0 = B0 + 1 is fine (B0 empty, no edges out). B0 = A0 + 1 closes the cycle.
        vm.startPrank(owner);
        sheet.setFormula(A, 0, Sheet.Op.ADD, _ref(B, 0), _const(1));
        vm.expectRevert(abi.encodeWithSelector(Sheet.CycleDetected.selector, _enc(B, 0)));
        sheet.setFormula(B, 0, Sheet.Op.ADD, _ref(A, 0), _const(1));
        vm.stopPrank();
    }

    function test_Cycle_ThreeHopIndirect() public {
        // A0 -> B0 -> C0, then C0 -> A0 must revert.
        vm.startPrank(owner);
        sheet.setFormula(A, 0, Sheet.Op.ADD, _ref(B, 0), _const(1));
        sheet.setFormula(B, 0, Sheet.Op.ADD, _ref(C, 0), _const(1));
        vm.expectRevert(abi.encodeWithSelector(Sheet.CycleDetected.selector, _enc(C, 0)));
        sheet.setFormula(C, 0, Sheet.Op.ADD, _ref(A, 0), _const(1));
        vm.stopPrank();
    }

    function test_Cycle_FourHopIndirect() public {
        vm.startPrank(owner);
        sheet.setFormula(A, 0, Sheet.Op.ADD, _ref(B, 0), _const(1));
        sheet.setFormula(B, 0, Sheet.Op.ADD, _ref(C, 0), _const(1));
        sheet.setFormula(C, 0, Sheet.Op.ADD, _ref(D, 0), _const(1));
        vm.expectRevert(abi.encodeWithSelector(Sheet.CycleDetected.selector, _enc(D, 0)));
        sheet.setFormula(D, 0, Sheet.Op.ADD, _ref(A, 0), _const(1));
        vm.stopPrank();
    }

    function test_Cycle_ThroughSumRange() public {
        // D0 = SUM(A0:B1); putting a formula in B1 that points back at D0 closes a cycle.
        vm.startPrank(owner);
        sheet.setSum(D, 0, A, 0, B, 1);
        vm.expectRevert(abi.encodeWithSelector(Sheet.CycleDetected.selector, _enc(B, 1)));
        sheet.setFormula(B, 1, Sheet.Op.ADD, _ref(D, 0), _const(1));
        vm.stopPrank();
    }

    function test_Cycle_SumRangeContainingItself() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Sheet.CycleDetected.selector, _enc(A, 0)));
        sheet.setSum(A, 0, A, 0, B, 1);
    }

    function test_Cycle_DiamondIsNotACycle() public {
        // A0 feeds both B0 and C0, which both feed D0. Shared subgraph, no cycle.
        vm.startPrank(owner);
        sheet.setLiteral(A, 0, 3);
        sheet.setFormula(B, 0, Sheet.Op.MUL, _ref(A, 0), _const(2)); // 6
        sheet.setFormula(C, 0, Sheet.Op.ADD, _ref(A, 0), _const(10)); // 13
        sheet.setFormula(D, 0, Sheet.Op.ADD, _ref(B, 0), _ref(C, 0)); // 19
        vm.stopPrank();
        assertEq(sheet.getValue(D, 0), 19);
    }

    function test_Cycle_FailedWriteLeavesCellUntouched() public {
        vm.startPrank(owner);
        sheet.setLiteral(A, 0, 7);
        sheet.setFormula(B, 0, Sheet.Op.ADD, _ref(A, 0), _const(1));
        // A0 = B0 + 1 would close a cycle; the revert must roll back the overwrite of A0.
        vm.expectRevert(abi.encodeWithSelector(Sheet.CycleDetected.selector, _enc(A, 0)));
        sheet.setFormula(A, 0, Sheet.Op.ADD, _ref(B, 0), _const(1));
        vm.stopPrank();

        assertEq(sheet.getValue(A, 0), 7);
        assertEq(sheet.getValue(B, 0), 8);
        assertEq(sheet.dependenciesOf(A, 0).length, 0);
    }

    /*//////////////////////////////////////////////////////////////
                             ERROR BEHAVIOUR
    //////////////////////////////////////////////////////////////*/

    function test_Revert_DivisionByZeroConstant() public {
        vm.startPrank(owner);
        sheet.setLiteral(A, 0, 10);
        sheet.setFormula(B, 0, Sheet.Op.DIV, _ref(A, 0), _const(0));
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(Sheet.DivisionByZero.selector, _enc(B, 0)));
        sheet.getValue(B, 0);
    }

    function test_Revert_DivisionByZeroFromReferencedCell() public {
        vm.startPrank(owner);
        sheet.setLiteral(A, 0, 10);
        sheet.setLiteral(A, 1, 0);
        sheet.setFormula(B, 0, Sheet.Op.DIV, _ref(A, 0), _ref(A, 1));
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(Sheet.DivisionByZero.selector, _enc(B, 0)));
        sheet.getValue(B, 0);
    }

    function test_Revert_ReadingEmptyCell() public {
        vm.expectRevert(abi.encodeWithSelector(Sheet.EmptyCellReference.selector, _enc(A, 0)));
        sheet.getValue(A, 0);
    }

    function test_Revert_FormulaReferencingEmptyCell() public {
        vm.prank(owner);
        sheet.setFormula(B, 0, Sheet.Op.ADD, _ref(A, 0), _const(1));

        vm.expectRevert(abi.encodeWithSelector(Sheet.EmptyCellReference.selector, _enc(A, 0)));
        sheet.getValue(B, 0);
    }

    function test_Revert_ClearingBreaksDependents() public {
        vm.startPrank(owner);
        sheet.setLiteral(A, 0, 1);
        sheet.setFormula(B, 0, Sheet.Op.ADD, _ref(A, 0), _const(1));
        assertEq(sheet.getValue(B, 0), 2);
        sheet.clearCell(A, 0);
        vm.stopPrank();

        assertTrue(sheet.isEmpty(A, 0));
        vm.expectRevert(abi.encodeWithSelector(Sheet.EmptyCellReference.selector, _enc(A, 0)));
        sheet.getValue(B, 0);
    }

    function test_Revert_TargetOutOfBounds() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Sheet.CellOutOfBounds.selector, uint16(64), uint16(0)));
        sheet.setLiteral(64, 0, 1);
    }

    function test_Revert_ReferenceOutOfBounds() public {
        Sheet.Operand memory bad = Sheet.Operand({ isRef: true, cell: _enc(0, 128), value: 0 });
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Sheet.CellOutOfBounds.selector, uint16(0), uint16(128)));
        sheet.setFormula(A, 0, Sheet.Op.ADD, bad, _const(1));
    }

    function test_Revert_ReadOutOfBoundsById() public {
        vm.expectRevert(abi.encodeWithSelector(Sheet.CellOutOfBounds.selector, uint16(999), uint16(0)));
        sheet.getValueById(_enc(999, 0));
    }

    function test_Revert_MaxDepthExceeded() public {
        // Build a chain longer than MAX_DEPTH: (0,0) literal, then (0,i) = (0,i-1) + 1.
        uint256 depth = sheet.MAX_DEPTH();
        vm.startPrank(owner);
        sheet.setLiteral(A, 0, 0);
        for (uint16 i = 1; i <= uint16(depth) + 1; ++i) {
            sheet.setFormula(A, i, Sheet.Op.ADD, _ref(A, i - 1), _const(1));
        }
        vm.stopPrank();

        // A chain of exactly MAX_DEPTH edges is still readable.
        assertEq(sheet.getValue(A, uint16(depth)), int256(depth));

        // One edge further and the guard fires, naming the deepest cell reached.
        vm.expectRevert(abi.encodeWithSelector(Sheet.MaxDepthExceeded.selector, _enc(A, 0)));
        sheet.getValue(A, uint16(depth) + 1);
    }

    function test_Revert_ArithmeticOverflowPanics() public {
        vm.startPrank(owner);
        sheet.setLiteral(A, 0, type(int256).max);
        sheet.setFormula(B, 0, Sheet.Op.ADD, _ref(A, 0), _const(1));
        vm.stopPrank();

        vm.expectRevert(stdError.arithmeticError);
        sheet.getValue(B, 0);
    }

    function test_Revert_ZeroDimensionConstructor() public {
        vm.expectRevert(Sheet.ZeroDimension.selector);
        new Sheet(0, 10, owner);
    }

    /*//////////////////////////////////////////////////////////////
                             ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/

    function test_Access_EditorMayWrite() public {
        vm.prank(editor);
        sheet.setLiteral(A, 0, 99);
        assertEq(sheet.getValue(A, 0), 99);
    }

    function test_Access_StrangerCannotWrite() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Sheet.NotEditor.selector, stranger));
        sheet.setLiteral(A, 0, 1);
    }

    function test_Access_StrangerCannotClear() public {
        vm.prank(owner);
        sheet.setLiteral(A, 0, 1);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Sheet.NotEditor.selector, stranger));
        sheet.clearCell(A, 0);

        assertEq(sheet.getValue(A, 0), 1);
    }

    function test_Access_RevokedEditorCannotWrite() public {
        vm.prank(owner);
        sheet.setEditor(editor, false);

        vm.prank(editor);
        vm.expectRevert(abi.encodeWithSelector(Sheet.NotEditor.selector, editor));
        sheet.setLiteral(A, 0, 1);
    }

    function test_Access_OnlyOwnerManagesEditors() public {
        vm.prank(editor);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", editor));
        sheet.setEditor(stranger, true);
        assertFalse(sheet.isEditor(stranger));
    }

    function test_Access_ReadsArePermissionless() public {
        vm.prank(owner);
        sheet.setLiteral(A, 0, 12);

        vm.prank(stranger);
        assertEq(sheet.getValue(A, 0), 12);
    }
}
