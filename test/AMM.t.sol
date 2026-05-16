// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, console2 } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { AMM } from "../src/AMM.sol";
import { MockERC20 } from "./helpers/MockERC20.sol";

/// @title AMMTest
/// @notice Unit tests for the AMM contract. Covers all public/external functions
///         including revert paths. Minimum 50 tests required.
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

        // Deploy AMM via UUPS proxy
        AMM impl = new AMM();
        bytes memory initData = abi.encodeCall(AMM.initialize, (address(tokenA), address(tokenB), owner));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        amm = AMM(address(proxy));

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

        // Bob gets half of Alice's LP (proportional)
        assertApproxEqAbs(lp2, lp1 / 2, 1000); // within 1000 wei rounding
    }

    function test_AddLiquidity_Revert_ZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(AMM.ZeroAmount.selector);
        amm.addLiquidity(0, LIQUIDITY_B, 0, 0);
    }

    function test_AddLiquidity_Revert_SlippageA() public {
        // First deposit to set ratio
        vm.prank(alice);
        amm.addLiquidity(LIQUIDITY_A, LIQUIDITY_B, 0, 0);

        // Bob tries to add with wrong ratio and tight slippage
        vm.prank(bob);
        vm.expectRevert(AMM.SlippageExceeded.selector);
        amm.addLiquidity(
            LIQUIDITY_A,
            LIQUIDITY_B,
            0,
            LIQUIDITY_B + 1 // impossible max B (1 wei too high)
        );
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
        // Dead address holds MINIMUM_LIQUIDITY
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
        amm.removeLiquidity(lp, type(uint256).max, 0); // impossible min A
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
        // Only minimum liquidity remains
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
        // Without fee: out = amountIn * reserveOut / (reserveIn + amountIn)
        uint256 noFeeOut = (amountIn * LIQUIDITY_B) / (LIQUIDITY_A + amountIn);
        uint256 withFeeOut = amm.getAmountOut(amountIn, LIQUIDITY_A, LIQUIDITY_B);
        assertLt(withFeeOut, noFeeOut); // fee reduces output
    }

    function test_Swap_Revert_InvalidToken() public {
        _setupPool();
        address fakeToken = makeAddr("fake");
        vm.prank(bob);
        vm.expectRevert(AMM.InvalidToken.selector);
        amm.swap(fakeToken, 1e18, 0);
    }

    function test_Swap_Revert_SlippageTooHigh() public {
        _setupPool();
        vm.prank(bob);
        vm.expectRevert(AMM.SlippageExceeded.selector);
        amm.swap(address(tokenA), 1_000e18, type(uint256).max);
    }

    function test_Swap_Revert_ZeroInput() public {
        _setupPool();
        vm.prank(bob);
        vm.expectRevert(AMM.InsufficientInputAmount.selector);
        amm.swap(address(tokenA), 0, 0);
    }

    function test_Swap_Revert_NoLiquidity() public {
        vm.prank(bob);
        vm.expectRevert(AMM.InsufficientLiquidity.selector);
        amm.swap(address(tokenA), 1e18, 0);
    }

    function test_Swap_KInvariantHolds() public {
        _setupPool();
        (uint256 rA0, uint256 rB0) = amm.getReserves();
        uint256 k0 = rA0 * rB0;

        vm.prank(bob);
        amm.swap(address(tokenA), 10_000e18, 0);

        (uint256 rA1, uint256 rB1) = amm.getReserves();
        uint256 k1 = rA1 * rB1;
        assertGe(k1, k0); // k never decreases
    }

    function test_Swap_EmitsEvent() public {
        _setupPool();
        vm.expectEmit(true, true, false, false, address(amm));
        emit AMM.Swap(bob, address(tokenA), 0, 0);
        vm.prank(bob);
        amm.swap(address(tokenA), 1_000e18, 0);
    }

    function test_Swap_Revert_WhenPaused() public {
        _setupPool();
        vm.prank(owner);
        amm.pause();
        vm.prank(bob);
        vm.expectRevert();
        amm.swap(address(tokenA), 1_000e18, 0);
    }

    // getAmountOut

    function test_GetAmountOut_CorrectFormula() public view {
        uint256 amountIn = 1_000e18;
        uint256 reserveIn = 100_000e18;
        uint256 reserveOut = 100_000e18;
        uint256 out = amm.getAmountOut(amountIn, reserveIn, reserveOut);
        // Expected: (1000 * 997 * 100000) / (100000 * 1000 + 1000 * 997) = ~987.15e18
        assertGt(out, 980e18);
        assertLt(out, 1_000e18);
    }

    function test_GetAmountOut_Revert_ZeroReserveIn() public {
        vm.expectRevert(AMM.InsufficientLiquidity.selector);
        amm.getAmountOut(1e18, 0, 1e18);
    }

    function test_GetAmountOut_Revert_ZeroReserveOut() public {
        vm.expectRevert(AMM.InsufficientLiquidity.selector);
        amm.getAmountOut(1e18, 1e18, 0);
    }

    // quote

    function test_Quote_CorrectRatio() public view {
        // 1:2 ratio
        uint256 q = amm.quote(100e18, 100e18, 200e18);
        assertEq(q, 200e18);
    }

    function test_Quote_Revert_ZeroAmount() public {
        vm.expectRevert(AMM.ZeroAmount.selector);
        amm.quote(0, 100e18, 200e18);
    }

    function test_Quote_Revert_ZeroReserves() public {
        vm.expectRevert(AMM.InsufficientLiquidity.selector);
        amm.quote(100e18, 0, 200e18);
    }

    // Pause / Unpause

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

    // UUPS upgrade

    function test_Upgrade_OnlyOwner() public {
        AMM newImpl = new AMM();
        vm.prank(alice);
        vm.expectRevert();
        amm.upgradeToAndCall(address(newImpl), "");
    }

    function test_Upgrade_OwnerSucceeds() public {
        AMM newImpl = new AMM();
        vm.prank(owner);
        amm.upgradeToAndCall(address(newImpl), "");
        assertEq(amm.version(), 1); // state preserved
    }

    function test_Upgrade_PreservesState() public {
        vm.prank(alice);
        amm.addLiquidity(LIQUIDITY_A, LIQUIDITY_B, 0, 0);

        AMM newImpl = new AMM();
        vm.prank(owner);
        amm.upgradeToAndCall(address(newImpl), "");

        (uint256 rA, uint256 rB) = amm.getReserves();
        assertEq(rA, LIQUIDITY_A);
        assertEq(rB, LIQUIDITY_B);
    }

    // Getters

    function test_GetReserves() public {
        (uint256 rA, uint256 rB) = amm.getReserves();
        assertEq(rA, 0);
        assertEq(rB, 0);
    }

    function test_TokenAddresses() public view {
        assertEq(address(amm.tokenA()), address(tokenA));
        assertEq(address(amm.tokenB()), address(tokenB));
    }

    function test_Version_IsOne() public view {
        assertEq(amm.version(), 1);
    }

    function test_FeeConstants() public view {
        assertEq(amm.FEE_NUMERATOR(), 997);
        assertEq(amm.FEE_DENOMINATOR(), 1000);
    }

    // Multiple swaps / large amounts

    function test_MultipleSwaps_KAlwaysGrows() public {
        _setupPool();
        (uint256 rA0, uint256 rB0) = amm.getReserves();
        uint256 k = rA0 * rB0;

        for (uint256 i = 0; i < 5; i++) {
            vm.prank(bob);
            amm.swap(address(tokenA), 100e18, 0);
            (uint256 rA, uint256 rB) = amm.getReserves();
            assertGe(rA * rB, k);
            k = rA * rB;
        }
    }

    function test_Swap_LargeAmount_DoesNotCrash() public {
        _setupPool();
        uint256 largeAmount = LIQUIDITY_A / 2; // 50% of pool
        tokenA.mint(carol, largeAmount);
        vm.startPrank(carol);
        tokenA.approve(address(amm), largeAmount);
        amm.swap(address(tokenA), largeAmount, 0);
        vm.stopPrank();
    }

    function test_RoundTrip_ApproxRefund() public {
        _setupPool();
        uint256 swapIn = 1_000e18;
        uint256 balBefore = tokenA.balanceOf(bob);

        vm.startPrank(bob);
        uint256 bOut = amm.swap(address(tokenA), swapIn, 0);
        tokenB.approve(address(amm), bOut);
        amm.swap(address(tokenB), bOut, 0);
        vm.stopPrank();

        uint256 balAfter = tokenA.balanceOf(bob);
        // After round-trip, bob has less due to 0.3% fee × 2
        assertLt(balAfter, balBefore);
        // But not too much less (< 1% of input)
        assertGt(balAfter, balBefore - swapIn / 100);
    }

    function test_AddLiquidity_SmallAmounts_AboveMinLiquidity() public {
        // sqrt(2000 * 2000) = 2000 > MINIMUM_LIQUIDITY (1000)
        vm.prank(alice);
        (uint256 aA, uint256 aB, uint256 lp) = amm.addLiquidity(2000, 2000, 0, 0);
        assertEq(aA, 2000);
        assertEq(aB, 2000);
        assertEq(lp, 1000); // 2000 - MINIMUM_LIQUIDITY
    }

    function test_AddLiquidity_Revert_TinyAmounts_BelowMinLiquidity() public {
        // sqrt(1 * 1) = 1 < MINIMUM_LIQUIDITY → revert
        vm.prank(alice);
        vm.expectRevert();
        amm.addLiquidity(1, 1, 0, 0);
    }

    function test_AddLiquidity_OptimalA_Branch() public {
        vm.prank(alice);
        amm.addLiquidity(LIQUIDITY_A, LIQUIDITY_B, 0, 0);

        // amountBDesired меньше оптимального → берём ветку amountAOptimal
        vm.prank(bob);
        amm.addLiquidity(LIQUIDITY_A, LIQUIDITY_B / 2, 0, 0);
    }
}
