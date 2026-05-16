// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {
    ERC1967Proxy
} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AMM} from "../src/AMM.sol";
import {YieldVault} from "../src/YieldVault.sol";
import {GovernanceToken} from "../src/GovernanceToken.sol";
import {MockAggregator} from "../src/mocks/MockAggregator.sol";
import {MockERC20} from "./helpers/MockERC20.sol";

/// @title FuzzTests
/// @notice Fuzz tests covering AMM swap, vault deposit/withdraw, and governance voting power.
///         Minimum 10 fuzz tests required by spec.
contract FuzzTests is Test {
    AMM public amm;
    YieldVault public vault;
    GovernanceToken public govToken;
    MockERC20 public tokenA;
    MockERC20 public tokenB;
    MockAggregator public feed;

    address public owner = makeAddr("owner");
    address public alice = makeAddr("alice");

    uint256 constant POOL_A = 1_000_000e18;
    uint256 constant POOL_B = 1_000_000e18;

    function setUp() public {
        tokenA = new MockERC20("A", "A");
        tokenB = new MockERC20("B", "B");
        govToken = new GovernanceToken(owner);
        feed = new MockAggregator(int256(2000e8), 8); // $2000, 8 decimals

        // AMM
        AMM impl = new AMM();
        bytes memory initData = abi.encodeCall(
            AMM.initialize,
            (address(tokenA), address(tokenB), owner)
        );
        amm = AMM(address(new ERC1967Proxy(address(impl), initData)));

        // Vault (tokenA as underlying)
        vault = new YieldVault(
            tokenA,
            owner,
            address(feed),
            3600,
            uint256(1e8)
        );

        // Seed pool
        tokenA.mint(owner, POOL_A * 10);
        tokenB.mint(owner, POOL_B * 10);
        vm.startPrank(owner);
        tokenA.approve(address(amm), type(uint256).max);
        tokenB.approve(address(amm), type(uint256).max);
        amm.addLiquidity(POOL_A, POOL_B, 0, 0);
        vm.stopPrank();
    }

    // AMM Fuzz tests

    /// @dev Fuzz 1: amountOut is always strictly less than reserveOut (pool can't be drained)
    function testFuzz_Swap_AmountOutLessThanReserve(uint256 amountIn) public {
        amountIn = bound(amountIn, 1000, POOL_A / 10); // up to 10% of pool

        tokenA.mint(alice, amountIn);
        vm.startPrank(alice);
        tokenA.approve(address(amm), amountIn);
        uint256 out = amm.swap(address(tokenA), amountIn, 0);
        vm.stopPrank();

        (, uint256 rB) = amm.getReserves();
        assertLt(out, rB + out); // out < original reserveB
        assertGt(out, 0);
    }

    /// @dev Fuzz 2: getAmountOut is monotone increasing in amountIn
    function testFuzz_GetAmountOut_Monotone(
        uint256 amountIn1,
        uint256 amountIn2
    ) public view {
        amountIn1 = bound(amountIn1, 1, POOL_A / 100);
        amountIn2 = bound(amountIn2, amountIn1, POOL_A / 100);

        uint256 out1 = amm.getAmountOut(amountIn1, POOL_A, POOL_B);
        uint256 out2 = amm.getAmountOut(amountIn2, POOL_A, POOL_B);
        assertGe(out2, out1);
    }

    /// @dev Fuzz 3: Fee always reduces output vs no-fee calculation
    function testFuzz_Swap_FeeAlwaysReducesOutput(
        uint256 amountIn
    ) public view {
        amountIn = bound(amountIn, 1e15, POOL_A / 10);
        uint256 feeOut = amm.getAmountOut(amountIn, POOL_A, POOL_B);
        uint256 noFeeOut = (amountIn * POOL_B) / (POOL_A + amountIn);
        assertLt(feeOut, noFeeOut);
    }

    /// @dev Fuzz 4: K invariant holds after arbitrary swap
    function testFuzz_Swap_KInvariant(uint256 amountIn) public {
        amountIn = bound(amountIn, 1e15, POOL_A / 10);
        (uint256 rA0, uint256 rB0) = amm.getReserves();
        uint256 k0 = rA0 * rB0;

        tokenA.mint(alice, amountIn);
        vm.startPrank(alice);
        tokenA.approve(address(amm), amountIn);
        amm.swap(address(tokenA), amountIn, 0);
        vm.stopPrank();

        (uint256 rA1, uint256 rB1) = amm.getReserves();
        assertGe(rA1 * rB1, k0);
    }

    /// @dev Fuzz 5: addLiquidity then removeLiquidity returns close to original amounts
    function testFuzz_AddRemoveLiquidity_RoundTrip(uint256 amountA) public {
        amountA = bound(amountA, 1e18, POOL_A / 100);
        uint256 amountB = amm.quote(amountA, POOL_A, POOL_B);

        tokenA.mint(alice, amountA);
        tokenB.mint(alice, amountB);
        vm.startPrank(alice);
        tokenA.approve(address(amm), amountA);
        tokenB.approve(address(amm), amountB);

        uint256 balABefore = tokenA.balanceOf(alice);
        (, , uint256 lp) = amm.addLiquidity(amountA, amountB, 0, 0);
        (uint256 retA, ) = amm.removeLiquidity(lp, 0, 0);
        vm.stopPrank();

        // Returned A is within 0.1% of deposited A (rounding / minimum liquidity)
        assertApproxEqRel(tokenA.balanceOf(alice), balABefore, 0.001e18);
    }

    // Vault Fuzz tests

    /// @dev Fuzz 6: deposit then redeem returns at most deposited amount (no inflation attack)
    function testFuzz_Vault_DepositRedeem_NoInflation(uint256 assets) public {
        assets = bound(assets, 1e6, 1_000_000e18);

        tokenA.mint(alice, assets);
        vm.startPrank(alice);
        tokenA.approve(address(vault), assets);
        uint256 shares = vault.deposit(assets, alice);
        uint256 returned = vault.redeem(shares, alice, alice);
        vm.stopPrank();

        // User gets back at most what they put in (never more due to rounding)
        assertLe(returned, assets);
        // But within 1 wei of assets (ERC-4626 rounding invariant)
        assertGe(returned, assets - 1);
    }

    /// @dev Fuzz 7: shares are proportional to assets (linear)
    function testFuzz_Vault_SharesProportional(
        uint256 assets1,
        uint256 assets2
    ) public {
        assets1 = bound(assets1, 1e18, 500_000e18);
        assets2 = bound(assets2, 1e18, 500_000e18);

        tokenA.mint(alice, assets1 + assets2);
        vm.startPrank(alice);
        tokenA.approve(address(vault), type(uint256).max);
        uint256 shares1 = vault.deposit(assets1, alice);
        uint256 shares2 = vault.deposit(assets2, alice);
        vm.stopPrank();

        // shares1 / assets1 ≈ shares2 / assets2 (within 1 wei)
        assertApproxEqAbs(
            shares1 * assets2,
            shares2 * assets1,
            assets1 + assets2 // rounding tolerance
        );
    }

    /// @dev Fuzz 8: previewDeposit matches actual deposit (within 1 wei)
    function testFuzz_Vault_PreviewDepositMatchesActual(uint256 assets) public {
        assets = bound(assets, 1e6, 1_000_000e18);

        uint256 preview = vault.previewDeposit(assets);

        tokenA.mint(alice, assets);
        vm.startPrank(alice);
        tokenA.approve(address(vault), assets);
        uint256 actual = vault.deposit(assets, alice);
        vm.stopPrank();

        assertEq(actual, preview);
    }

    // Governance Fuzz tests

    /// @dev Fuzz 9: voting power equals delegated balance at a block
    function testFuzz_VotingPower_EqualsDelegatedBalance(
        uint256 amount
    ) public {
        amount = bound(amount, 1e18, 1_000_000e18);
        if (amount > govToken.MAX_SUPPLY() - govToken.totalSupply()) return;

        vm.prank(owner);
        govToken.mint(alice, amount);

        vm.prank(alice);
        govToken.delegate(alice);

        vm.roll(block.number + 1);
        assertEq(govToken.getVotes(alice), govToken.balanceOf(alice));
    }

    /// @dev Fuzz 10: delegation transfers voting power correctly
    function testFuzz_Delegation_TransfersVotingPower(uint256 amount) public {
        amount = bound(amount, 1e18, 100_000e18);
        vm.prank(owner);
        govToken.mint(alice, amount);

        // Before delegation: no voting power
        assertEq(govToken.getVotes(alice), 0);

        vm.prank(alice);
        govToken.delegate(alice);

        // After delegation: full balance
        assertEq(govToken.getVotes(alice), govToken.balanceOf(alice));

        // Delegate to bob
        address bob_ = makeAddr("bob");
        vm.prank(alice);
        govToken.delegate(bob_);

        assertEq(govToken.getVotes(alice), 0);
        assertEq(govToken.getVotes(bob_), govToken.balanceOf(alice));
    }
}
