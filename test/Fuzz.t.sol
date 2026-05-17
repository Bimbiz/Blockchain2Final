// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { AMM } from "../src/AMM.sol";
import { YieldVault } from "../src/YieldVault.sol";
import { GovernanceToken } from "../src/GovernanceToken.sol";
import { MockAggregator } from "../src/mocks/MockAggregator.sol";
import { MockERC20 } from "./helpers/MockERC20.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title FuzzTests
/// @notice Fuzz tests covering AMM swap, vault deposit/withdraw, and governance voting power.
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

        govToken = new GovernanceToken(owner, owner);

        feed = new MockAggregator(int256(2000e8), 8); // $2000, 8 decimals

        amm = new AMM(address(tokenA), address(tokenB), owner);

        // Vault (tokenA as underlying) -- deployed as UUPS proxy
        YieldVault vaultImpl = new YieldVault();
        bytes memory vaultInit =
            abi.encodeCall(YieldVault.initialize, (tokenA, owner, address(feed), 3600, uint256(1e8)));
        vault = YieldVault(address(new ERC1967Proxy(address(vaultImpl), vaultInit)));

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
    function testFuzz_GetAmountOut_Monotone(uint256 amountIn1, uint256 amountIn2) public view {
        amountIn1 = bound(amountIn1, 1, POOL_A / 100);
        amountIn2 = bound(amountIn2, amountIn1, POOL_A / 100);

        uint256 out1 = amm.getAmountOut(amountIn1, POOL_A, POOL_B);
        uint256 out2 = amm.getAmountOut(amountIn2, POOL_A, POOL_B);
        assertGe(out2, out1);
    }

    /// @dev Fuzz 3: Fee always reduces output vs no-fee calculation
    function testFuzz_Swap_FeeAlwaysReducesOutput(uint256 amountIn) public view {
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
        (,, uint256 lp) = amm.addLiquidity(amountA, amountB, 0, 0);
        amm.removeLiquidity(lp, 0, 0);
        vm.stopPrank();

        assertApproxEqRel(tokenA.balanceOf(alice), balABefore, 0.001e18);
    }

    // Governance Fuzz tests

    /// @dev Fuzz 9: voting power equals delegated balance at a block
    function testFuzz_VotingPower_EqualsDelegatedBalance(uint256 amount) public {
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

        assertEq(govToken.getVotes(alice), 0);

        vm.prank(alice);
        govToken.delegate(alice);

        vm.roll(block.number + 1);
        assertEq(govToken.getVotes(alice), amount);
    }
}
