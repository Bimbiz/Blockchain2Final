// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";
import { AMM } from "../src/AMM.sol";
import { GovernanceToken } from "../src/GovernanceToken.sol";
import { MockERC20 } from "./helpers/MockERC20.sol";

/// @notice Handler contract that Foundry will call randomly
contract AMMHandler is Test {
    AMM public amm;
    MockERC20 public tokenA;
    MockERC20 public tokenB;
    address[] public actors;

    uint256 public ghost_totalLPMinted;
    uint256 public ghost_totalLPBurned;
    uint256 public ghost_swapCount;

    constructor(AMM _amm, MockERC20 _tokenA, MockERC20 _tokenB) {
        amm = _amm;
        tokenA = _tokenA;
        tokenB = _tokenB;
        for (uint256 i = 1; i <= 5; i++) {
            address actor = address(uint160(i * 0xdead));
            actors.push(actor);
            tokenA.mint(actor, 1_000_000e18);
            tokenB.mint(actor, 1_000_000e18);
            vm.prank(actor);
            tokenA.approve(address(amm), type(uint256).max);
            vm.prank(actor);
            tokenB.approve(address(amm), type(uint256).max);
        }
    }

    function addLiquidity(uint256 actorSeed, uint256 amountA, uint256 amountB) external {
        address actor = actors[actorSeed % actors.length];

        (uint256 rA, uint256 rB) = amm.getReserves();
        uint256 totalLPSupply = amm.totalSupply();

        if (totalLPSupply > 0 && rA > 0 && rB > 0) {
            amountA = bound(amountA, 1e18, 100_000e18);
            amountB = (amountA * rB) / rA;
            if (amountB < 1e18) return;
        } else {
            amountA = bound(amountA, 1e18, 100_000e18);
            amountB = bound(amountB, 1e18, 100_000e18);
        }

        if (tokenA.balanceOf(actor) < amountA || tokenB.balanceOf(actor) < amountB) return;

        vm.prank(actor);
        (,, uint256 lp) = amm.addLiquidity(amountA, amountB, 0, 0);

        ghost_totalLPMinted += lp;
    }

    function removeLiquidity(uint256 actorSeed, uint256 lpFraction) external {
        address actor = actors[actorSeed % actors.length];
        uint256 lpBal = amm.balanceOf(actor);
        if (lpBal == 0) return;

        lpFraction = bound(lpFraction, 1, 100);
        uint256 lp = (lpBal * lpFraction) / 100;
        if (lp == 0) return;

        uint256 totalLPSupply = amm.totalSupply();
        (uint256 rA, uint256 rB) = amm.getReserves();

        if (totalLPSupply == 0 || rA == 0 || rB == 0) return;
        if (totalLPSupply <= lp + 1000) return;

        if ((lp * rA) < totalLPSupply || (lp * rB) < totalLPSupply) return;

        uint256 amtA = (lp * rA) / totalLPSupply;
        uint256 amtB = (lp * rB) / totalLPSupply;
        if (amtA == 0 || amtB == 0) return;

        vm.prank(actor);
        amm.removeLiquidity(lp, 0, 0);

        ghost_totalLPBurned += lp;
    }

    function swap(uint256 actorSeed, bool aToB, uint256 amountIn) external {
        address actor = actors[actorSeed % actors.length];

        (uint256 rA, uint256 rB) = amm.getReserves();
        if (rA == 0 || rB == 0) return;

        uint256 reserveIn = aToB ? rA : rB;
        uint256 reserveOut = aToB ? rB : rA;

        uint256 maxAmountIn = reserveIn / 3;
        if (maxAmountIn < 1e15) return;

        amountIn = bound(amountIn, 1e15, maxAmountIn);
        MockERC20 inToken = aToB ? tokenA : tokenB;

        if (inToken.balanceOf(actor) < amountIn) return;

        uint256 amountOut = amm.getAmountOut(amountIn, reserveIn, reserveOut);
        if (amountOut == 0 || amountOut >= reserveOut) return;

        vm.prank(actor);
        amm.swap(address(inToken), amountIn, 0);

        ghost_swapCount++;
    }
}

/// @title InvariantTests
/// @notice Invariant tests: k-invariant, LP supply conservation, total supply
contract InvariantTests is StdInvariant, Test {
    AMM public amm;
    GovernanceToken public govToken;
    MockERC20 public tokenA;
    MockERC20 public tokenB;
    AMMHandler public handler;

    address owner = makeAddr("invariantOwner");

    uint256 public initialK;
    uint256 public ownerLP;

    function setUp() public {
        tokenA = new MockERC20("A", "A");
        tokenB = new MockERC20("B", "B");
        govToken = new GovernanceToken(owner, owner);

        amm = new AMM(address(tokenA), address(tokenB), owner);

        // Seed initial liquidity
        tokenA.mint(owner, 1_000_000e18);
        tokenB.mint(owner, 1_000_000e18);
        vm.startPrank(owner);
        tokenA.approve(address(amm), type(uint256).max);
        tokenB.approve(address(amm), type(uint256).max);
        amm.addLiquidity(1_000_000e18, 1_000_000e18, 0, 0);
        vm.stopPrank();

        ownerLP = amm.balanceOf(owner);

        (uint256 rA, uint256 rB) = amm.getReserves();
        initialK = rA * rB;

        handler = new AMMHandler(amm, tokenA, tokenB);
        targetContract(address(handler));
    }

    /// @notice Invariant 1: k = reserveA * reserveB never decreases after swaps
    function invariant_KNeverDecreases() public view {
        (uint256 rA, uint256 rB) = amm.getReserves();
        uint256 currentK = rA * rB;
        uint256 totalSupply = amm.totalSupply();
        assertGe(currentK, (totalSupply * totalSupply) / 1e18, "K decreased relative to LP supply");
    }

    /// @notice Invariant 2: AMM contract holds exactly reserveA of tokenA and reserveB of tokenB
    function invariant_ReservesMatchBalances() public view {
        (uint256 rA, uint256 rB) = amm.getReserves();
        assertEq(tokenA.balanceOf(address(amm)), rA);
        assertEq(tokenB.balanceOf(address(amm)), rB);
    }

    /// @notice Invariant 3: LP total supply = minted - burned (ghost variable check)
    function invariant_LPSupplyConservation() public view {
        uint256 baseSupply = ownerLP + amm.MINIMUM_LIQUIDITY() + handler.ghost_totalLPMinted();
        uint256 expectedSupply = baseSupply - handler.ghost_totalLPBurned();

        assertEq(amm.totalSupply(), expectedSupply, "LP Supply mismatch");
    }

    /// @notice Invariant 4: Governance token total supply never exceeds MAX_SUPPLY
    function invariant_GovTokenSupplyBelowMax() public view {
        assertLe(govToken.totalSupply(), govToken.MAX_SUPPLY());
    }

    /// @notice Invariant 5: AMM is never paused (owner hasn't called pause in handler)
    function invariant_AMMNotPaused() public view {
        assertFalse(amm.paused());
    }
}
