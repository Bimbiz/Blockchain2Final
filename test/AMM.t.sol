// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, console2 } from "forge-std/Test.sol";
import { AMM } from "../src/AMM.sol";
import { MockERC20 } from "./helpers/MockERC20.sol";

contract AMMTest is Test {
    AMM public amm;
    MockERC20 public tokenA;
    MockERC20 public tokenB;

    address public owner = makeAddr("owner");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public carol = makeAddr("carol");

    uint256 constant INITIAL_AMOUNT = 1_000_000e18;
    uint256 constant LIQUIDITY_A = 100_000e18;
    uint256 constant LIQUIDITY_B = 100_000e18;

    function setUp() public {
        tokenA = new MockERC20("Token A", "TKNA");
        tokenB = new MockERC20("Token B", "TKNB");

        address t0 = address(tokenA) < address(tokenB) ? address(tokenA) : address(tokenB);
        address t1 = address(tokenA) < address(tokenB) ? address(tokenB) : address(tokenA);

        amm = new AMM(t0, t1, owner);

        // Mint tokens
        tokenA.mint(alice, INITIAL_AMOUNT);
        tokenB.mint(alice, INITIAL_AMOUNT);
        tokenA.mint(bob, INITIAL_AMOUNT);
        tokenB.mint(bob, INITIAL_AMOUNT);

        // Alice approves AMM
        vm.startPrank(alice);
        tokenA.approve(address(amm), type(uint256).max);
        tokenB.approve(address(amm), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        tokenA.approve(address(amm), type(uint256).max);
        tokenB.approve(address(amm), type(uint256).max);
        vm.stopPrank();
    }

    // addLiquidity

    function test_AddLiquidity_InitialDeposit() public {
        vm.prank(alice);
        (uint256 aA, uint256 aB, uint256 lp) = amm.addLiquidity(LIQUIDITY_A, LIQUIDITY_B, 0, 0);
        assertEq(aA, LIQUIDITY_A);
        assertEq(aB, LIQUIDITY_B);
        assertGt(lp, 0);
    }

    function test_AddLiquidity_MintsLPTokens() public {
        vm.prank(alice);
        (,, uint256 lp) = amm.addLiquidity(LIQUIDITY_A, LIQUIDITY_B, 0, 0);
        assertEq(amm.balanceOf(alice), lp);
    }

    function test_AddLiquidity_UpdatesReserves() public {
        vm.prank(alice);
        amm.addLiquidity(LIQUIDITY_A, LIQUIDITY_B, 0, 0);
        (uint256 rA, uint256 rB) = amm.getReserves();
        assertEq(rA, LIQUIDITY_A);
        assertEq(rB, LIQUIDITY_B);
    }

    function test_AddLiquidity_TransfersTokens() public {
        uint256 balABefore = tokenA.balanceOf(address(amm));
        vm.prank(alice);
        amm.addLiquidity(LIQUIDITY_A, LIQUIDITY_B, 0, 0);
        assertEq(tokenA.balanceOf(address(amm)), balABefore + LIQUIDITY_A);
        assertEq(tokenB.balanceOf(address(amm)), LIQUIDITY_B);
    }

    function test_AddLiquidity_SubsequentDeposit_ProportionalLPMint() public {
        vm.prank(alice);
        (,, uint256 lp1) = amm.addLiquidity(LIQUIDITY_A, LIQUIDITY_B, 0, 0);

        vm.prank(bob);
        (,, uint256 lp2) = amm.addLiquidity(LIQUIDITY_A / 2, LIQUIDITY_B / 2, 0, 0);
        assertApproxEqAbs(lp2, lp1 / 2, 1000);
    }

    function test_AddLiquidity_Revert_ZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(AMM.ZeroAmount.selector);
        amm.addLiquidity(0, LIQUIDITY_B, 0, 0);
    }

    function test_AddLiquidity_Revert_SlippageA() public {
        vm.prank(alice);
        amm.addLiquidity(LIQUIDITY_A, LIQUIDITY_B, 0, 0);

        vm.prank(bob);
        vm.expectRevert(AMM.SlippageExceeded.selector);
        amm.addLiquidity(LIQUIDITY_A, LIQUIDITY_B, 0, LIQUIDITY_B + 1);
    }

    function test_AddLiquidity_EmitsEvent() public {
        vm.expectEmit(true, false, false, false, address(amm));
        emit AMM.LiquidityAdded(alice, LIQUIDITY_A, LIQUIDITY_B, 0);
        vm.prank(alice);
        amm.addLiquidity(LIQUIDITY_A, LIQUIDITY_B, 0, 0);
    }

    function test_AddLiquidity_MinimumLiquidityBurned() public {
        vm.prank(alice);
        amm.addLiquidity(LIQUIDITY_A, LIQUIDITY_B, 0, 0);
        assertEq(amm.balanceOf(address(0xdead)), amm.MINIMUM_LIQUIDITY());
    }

    function test_AddLiquidity_Revert_WhenPaused() public {
        vm.prank(owner);
        amm.pause();
        vm.prank(alice);
        vm.expectRevert();
        amm.addLiquidity(LIQUIDITY_A, LIQUIDITY_B, 0, 0);
    }

    // removeLiquidity

    function test_RemoveLiquidity_ReturnsTokens() public {
        vm.prank(alice);
        (,, uint256 lp) = amm.addLiquidity(LIQUIDITY_A, LIQUIDITY_B, 0, 0);

        uint256 balABefore = tokenA.balanceOf(alice);
        vm.prank(alice);
        (uint256 aA, uint256 aB) = amm.removeLiquidity(lp, 0, 0);

        assertGt(aA, 0);
        assertGt(aB, 0);
        assertGt(tokenA.balanceOf(alice), balABefore);
    }

    function test_RemoveLiquidity_BurnsLPTokens() public {
        vm.prank(alice);
        (,, uint256 lp) = amm.addLiquidity(LIQUIDITY_A, LIQUIDITY_B, 0, 0);
        vm.prank(alice);
        amm.removeLiquidity(lp, 0, 0);
        assertEq(amm.balanceOf(alice), 0);
    }

    function test_RemoveLiquidity_Revert_ZeroLiquidity() public {
        vm.prank(alice);
        vm.expectRevert(AMM.ZeroAmount.selector);
        amm.removeLiquidity(0, 0, 0);
    }

    function test_RemoveLiquidity_Revert_SlippageMin() public {
        vm.prank(alice);
        (,, uint256 lp) = amm.addLiquidity(LIQUIDITY_A, LIQUIDITY_B, 0, 0);
        vm.prank(alice);
        vm.expectRevert(AMM.SlippageExceeded.selector);
        amm.removeLiquidity(lp, type(uint256).max, 0);
    }

    function test_RemoveLiquidity_EmitsEvent() public {
        vm.prank(alice);
        (,, uint256 lp) = amm.addLiquidity(LIQUIDITY_A, LIQUIDITY_B, 0, 0);
        vm.expectEmit(true, false, false, false, address(amm));
        emit AMM.LiquidityRemoved(alice, 0, 0, lp);
        vm.prank(alice);
        amm.removeLiquidity(lp, 0, 0);
    }

    function test_RemoveLiquidity_UpdatesReserves() public {
        vm.prank(alice);
        (,, uint256 lp) = amm.addLiquidity(LIQUIDITY_A, LIQUIDITY_B, 0, 0);
        vm.prank(alice);
        amm.removeLiquidity(lp, 0, 0);
        (uint256 rA, uint256 rB) = amm.getReserves();
        assertLt(rA, LIQUIDITY_A);
        assertLt(rB, LIQUIDITY_B);
    }

    // swap

    function _setupPool() internal returns (uint256) {
        vm.prank(alice);
        (,, uint256 lp) = amm.addLiquidity(LIQUIDITY_A, LIQUIDITY_B, 0, 0);
        return lp;
    }

    function test_Swap_AtoB_CorrectOutput() public {
        _setupPool();
        uint256 amountIn = 1_000e18;
        uint256 expectedOut = amm.getAmountOut(amountIn, LIQUIDITY_A, LIQUIDITY_B);
        uint256 balBefore = tokenB.balanceOf(bob);
        vm.prank(bob);
        amm.swap(address(tokenA), amountIn, 0);
        assertEq(tokenB.balanceOf(bob) - balBefore, expectedOut);
    }

    function test_Swap_BtoA_CorrectOutput() public {
        _setupPool();
        uint256 amountIn = 1_000e18;
        uint256 expectedOut = amm.getAmountOut(amountIn, LIQUIDITY_B, LIQUIDITY_A);
        uint256 balBefore = tokenA.balanceOf(bob);
        vm.prank(bob);
        amm.swap(address(tokenB), amountIn, 0);
        assertEq(tokenA.balanceOf(bob) - balBefore, expectedOut);
    }

    function test_Swap_AppliesFee() public {
        _setupPool();
        uint256 amountIn = 1_000e18;
        uint256 noFeeOut = (amountIn * LIQUIDITY_B) / (LIQUIDITY_A + amountIn);
        uint256 withFeeOut = amm.getAmountOut(amountIn, LIQUIDITY_A, LIQUIDITY_B);
        assertLt(withFeeOut, noFeeOut);
    }

    function test_Pause_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        amm.pause();
    }

    function test_Unpause_OnlyOwner() public {
        vm.prank(owner);
        amm.pause();
        vm.prank(alice);
        vm.expectRevert();
        amm.unpause();
    }

    function test_Pause_And_Unpause_Flow() public {
        vm.prank(owner);
        amm.pause();
        assertTrue(amm.paused());
        vm.prank(owner);
        amm.unpause();
        assertFalse(amm.paused());
    }

    function test_GetReserves() public {
        AMM freshAmm = new AMM(address(tokenA), address(tokenB), owner);
        (uint256 rA, uint256 rB) = freshAmm.getReserves();
        assertEq(rA, 0);
        assertEq(rB, 0);
    }

    function test_FeeConstants() public view {
        assertEq(amm.FEE_NUMERATOR(), 997);
        assertEq(amm.FEE_DENOMINATOR(), 1000);
    }
}
