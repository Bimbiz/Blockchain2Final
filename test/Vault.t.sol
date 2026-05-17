// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, console2 } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { YieldVault } from "../src/YieldVault.sol";
import { MockAggregator } from "../src/mocks/MockAggregator.sol";
import { MockERC20 } from "./helpers/MockERC20.sol";

contract VaultTest is Test {
    YieldVault public vault;
    MockERC20 public asset;
    MockAggregator public feed;

    address public admin = makeAddr("admin");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public nobody = makeAddr("nobody");

    uint256 constant INITIAL_PRICE = 2000e8; // $2000, 8 decimals
    uint256 constant MIN_PRICE = 1e8; // $1
    uint256 constant MAX_STALENESS = 3600; // 1 hour
    uint256 constant DEPOSIT_AMOUNT = 10_000e18;

    function setUp() public {
        asset = new MockERC20("Test Asset", "TST");
        feed = new MockAggregator(int256(INITIAL_PRICE), 8);

        // Deploy implementation
        YieldVault impl = new YieldVault();

        // Encode initializer call
        bytes memory initData =
            abi.encodeCall(YieldVault.initialize, (asset, admin, address(feed), MAX_STALENESS, MIN_PRICE));

        // Deploy UUPS proxy
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        vault = YieldVault(address(proxy));

        asset.mint(alice, 1_000_000e18);
        asset.mint(bob, 1_000_000e18);

        vm.prank(alice);
        asset.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        asset.approve(address(vault), type(uint256).max);
    }

    // deposit

    function test_Deposit_MintsShares() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(DEPOSIT_AMOUNT, alice);
        assertGt(shares, 0);
        assertEq(vault.balanceOf(alice), shares);
    }

    function test_Deposit_TransfersAssets() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, alice);
        assertEq(asset.balanceOf(address(vault)), DEPOSIT_AMOUNT);
    }

    function test_Deposit_TotalAssetsIncreases() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, alice);
        assertEq(vault.totalAssets(), DEPOSIT_AMOUNT);
    }

    function test_Deposit_ToOtherReceiver() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, bob);
        assertEq(vault.balanceOf(bob), vault.totalSupply());
        assertEq(vault.balanceOf(alice), 0);
    }

    function test_Deposit_Revert_StalePrice() public {
        // Disable bypass so price check is active
        vm.prank(admin);
        vault.setBypassPriceCheck(false);

        vm.warp(block.timestamp + MAX_STALENESS + 2); // ensure timestamp > staleness
        feed.setUpdatedAt(block.timestamp - MAX_STALENESS - 1);
        vm.prank(alice);
        vm.expectRevert(YieldVault.StalePrice.selector);
        vault.deposit(DEPOSIT_AMOUNT, alice);
    }

    function test_Deposit_Revert_PriceBelowMinimum() public {
        // Disable bypass so price check is active
        vm.prank(admin);
        vault.setBypassPriceCheck(false);

        feed.setPrice(int256(MIN_PRICE) - 1);
        vm.prank(alice);
        vm.expectRevert();
        vault.deposit(DEPOSIT_AMOUNT, alice);
    }

    function test_Deposit_Revert_WhenPaused() public {
        vm.prank(admin);
        vault.pause();
        vm.prank(alice);
        vm.expectRevert();
        vault.deposit(DEPOSIT_AMOUNT, alice);
    }

    // mint

    function test_Mint_ByShares() public {
        // First deposit to set exchange rate
        vm.prank(alice);
        uint256 aliceShares = vault.deposit(DEPOSIT_AMOUNT, alice);

        // Bob mints a specific number of shares
        uint256 sharesToMint = aliceShares / 2;
        uint256 assetsNeeded = vault.previewMint(sharesToMint);

        vm.prank(bob);
        uint256 assetsUsed = vault.mint(sharesToMint, bob);

        assertEq(vault.balanceOf(bob), sharesToMint);
        assertEq(assetsUsed, assetsNeeded);
    }

    function test_Mint_Revert_StalePrice() public {
        // Disable bypass so price check is active
        vm.prank(admin);
        vault.setBypassPriceCheck(false);

        vm.warp(block.timestamp + MAX_STALENESS + 2);
        feed.setUpdatedAt(block.timestamp - MAX_STALENESS - 1);
        vm.prank(alice);
        vm.expectRevert(YieldVault.StalePrice.selector);
        vault.mint(1000e18, alice);
    }

    function test_Mint_Revert_WhenPaused() public {
        vm.prank(admin);
        vault.pause();
        vm.prank(alice);
        vm.expectRevert();
        vault.mint(1000e18, alice);
    }

    // withdraw

    function test_Withdraw_ByAssetAmount() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, alice);

        uint256 withdrawAmount = DEPOSIT_AMOUNT / 2;
        uint256 balBefore = asset.balanceOf(alice);

        vm.prank(alice);
        uint256 sharesBurned = vault.withdraw(withdrawAmount, alice, alice);

        assertGt(sharesBurned, 0);
        assertEq(asset.balanceOf(alice) - balBefore, withdrawAmount);
    }

    function test_Withdraw_ToOtherReceiver() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, alice);

        uint256 balBefore = asset.balanceOf(bob);
        vm.prank(alice);
        vault.withdraw(DEPOSIT_AMOUNT / 2, bob, alice);

        assertGt(asset.balanceOf(bob) - balBefore, 0);
    }

    function test_Withdraw_Revert_WhenPaused() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, alice);

        vm.prank(admin);
        vault.pause();

        vm.prank(alice);
        vm.expectRevert();
        vault.withdraw(DEPOSIT_AMOUNT / 2, alice, alice);
    }

    function test_Withdraw_Revert_InsufficientShares() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, alice);

        vm.prank(alice);
        vm.expectRevert();
        vault.withdraw(DEPOSIT_AMOUNT * 10, alice, alice); // more than deposited
    }

    // redeem

    function test_Redeem_ByShares() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(DEPOSIT_AMOUNT, alice);

        uint256 balBefore = asset.balanceOf(alice);
        vm.prank(alice);
        uint256 assetsReturned = vault.redeem(shares, alice, alice);

        assertGt(assetsReturned, 0);
        assertEq(asset.balanceOf(alice) - balBefore, assetsReturned);
        assertEq(vault.balanceOf(alice), 0);
    }

    function test_Redeem_ToOtherReceiver() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(DEPOSIT_AMOUNT, alice);

        uint256 balBefore = asset.balanceOf(bob);
        vm.prank(alice);
        vault.redeem(shares, bob, alice);

        assertGt(asset.balanceOf(bob) - balBefore, 0);
    }

    function test_Redeem_Revert_WhenPaused() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(DEPOSIT_AMOUNT, alice);

        vm.prank(admin);
        vault.pause();

        vm.prank(alice);
        vm.expectRevert();
        vault.redeem(shares, alice, alice);
    }

    function test_Redeem_Revert_InsufficientShares() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, alice);

        uint256 aliceShares = vault.balanceOf(alice);

        // Bob tries to redeem alice's shares without approval
        vm.prank(bob);
        vm.expectRevert();
        vault.redeem(aliceShares, bob, alice);
    }

    // ERC-4626 rounding invariants

    function test_PreviewDeposit_MatchesActual() public {
        uint256 preview = vault.previewDeposit(DEPOSIT_AMOUNT);
        vm.prank(alice);
        uint256 actual = vault.deposit(DEPOSIT_AMOUNT, alice);
        assertEq(actual, preview);
    }

    function test_PreviewRedeem_MatchesActual() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(DEPOSIT_AMOUNT, alice);

        uint256 preview = vault.previewRedeem(shares);
        vm.prank(alice);
        uint256 actual = vault.redeem(shares, alice, alice);
        assertEq(actual, preview);
    }

    function test_PreviewWithdraw_MatchesActual() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, alice);

        uint256 withdrawAmount = DEPOSIT_AMOUNT / 2;
        uint256 previewShares = vault.previewWithdraw(withdrawAmount);

        vm.prank(alice);
        uint256 actualShares = vault.withdraw(withdrawAmount, alice, alice);
        assertEq(actualShares, previewShares);
    }

    function test_ConvertToShares_RoundsDown() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, alice);

        // convertToShares should round DOWN (never give user more shares)
        uint256 shares = vault.convertToShares(DEPOSIT_AMOUNT - 1);
        assertLe(shares, vault.convertToShares(DEPOSIT_AMOUNT));
    }

    function test_ConvertToAssets_RoundsDown() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(DEPOSIT_AMOUNT, alice);

        // convertToAssets should round DOWN (never give user more assets)
        uint256 assets = vault.convertToAssets(shares - 1);
        assertLe(assets, vault.convertToAssets(shares));
    }

    // distributeYield

    function test_DistributeYield_IncreasesSharePrice() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(DEPOSIT_AMOUNT, alice);

        uint256 assetsBefore = vault.convertToAssets(shares);

        // Inject yield directly into vault
        uint256 yieldAmount = 1_000e18;
        asset.mint(address(vault), yieldAmount);

        vm.prank(admin);
        vault.distributeYield(yieldAmount);

        uint256 assetsAfter = vault.convertToAssets(shares);
        assertGt(assetsAfter, assetsBefore);
    }

    function test_DistributeYield_AccruedYieldTracked() public {
        uint256 yieldAmount = 500e18;
        asset.mint(address(vault), yieldAmount);

        vm.prank(admin);
        vault.distributeYield(yieldAmount);

        assertEq(vault.accruedYield(), yieldAmount);
    }

    function test_DistributeYield_Revert_Unauthorized() public {
        vm.prank(nobody);
        vm.expectRevert();
        vault.distributeYield(1000e18);
    }

    function test_DistributeYield_MultipleDepositors_FairShare() public {
        // Alice and Bob deposit equal amounts
        vm.prank(alice);
        uint256 aliceShares = vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.prank(bob);
        uint256 bobShares = vault.deposit(DEPOSIT_AMOUNT, bob);

        // Inject yield
        uint256 yieldAmount = 2_000e18;
        asset.mint(address(vault), yieldAmount);
        vm.prank(admin);
        vault.distributeYield(yieldAmount);

        // Both should get equal yield (equal shares)
        assertEq(vault.convertToAssets(aliceShares), vault.convertToAssets(bobShares));
    }

    // setPriceFeed

    function test_SetPriceFeed_UpdatesFeed() public {
        MockAggregator newFeed = new MockAggregator(int256(3000e8), 8);
        vm.prank(admin);
        vault.setPriceFeed(address(newFeed));
        assertEq(address(vault.priceFeed()), address(newFeed));
    }

    function test_SetPriceFeed_EmitsEvent() public {
        MockAggregator newFeed = new MockAggregator(int256(3000e8), 8);
        vm.expectEmit(false, false, false, true, address(vault));
        emit YieldVault.PriceFeedUpdated(address(newFeed));
        vm.prank(admin);
        vault.setPriceFeed(address(newFeed));
    }

    function test_SetPriceFeed_Revert_ZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(YieldVault.InvalidFeed.selector);
        vault.setPriceFeed(address(0));
    }

    function test_SetPriceFeed_Revert_Unauthorized() public {
        MockAggregator newFeed = new MockAggregator(int256(3000e8), 8);
        vm.prank(nobody);
        vm.expectRevert();
        vault.setPriceFeed(address(newFeed));
    }

    // setMaxStaleness

    function test_SetMaxStaleness_Updates() public {
        vm.prank(admin);
        vault.setMaxStaleness(7200);
        assertEq(vault.maxStaleness(), 7200);
    }

    function test_SetMaxStaleness_EmitsEvent() public {
        vm.expectEmit(false, false, false, true, address(vault));
        emit YieldVault.MaxStalenessUpdated(7200);
        vm.prank(admin);
        vault.setMaxStaleness(7200);
    }

    function test_SetMaxStaleness_Revert_Unauthorized() public {
        vm.prank(nobody);
        vm.expectRevert();
        vault.setMaxStaleness(7200);
    }

    // pause / unpause

    function test_Pause_OnlyPauserRole() public {
        vm.prank(nobody);
        vm.expectRevert();
        vault.pause();
    }

    function test_Unpause_OnlyPauserRole() public {
        vm.prank(admin);
        vault.pause();
        vm.prank(nobody);
        vm.expectRevert();
        vault.unpause();
    }

    function test_Pause_And_Unpause_Flow() public {
        vm.prank(admin);
        vault.pause();
        assertTrue(vault.paused());

        vm.prank(admin);
        vault.unpause();
        assertFalse(vault.paused());

        // Deposit works again after unpause
        vm.prank(alice);
        uint256 shares = vault.deposit(DEPOSIT_AMOUNT, alice);
        assertGt(shares, 0);
    }

    // totalAssets / maxDeposit / maxMint

    function test_TotalAssets_Empty() public view {
        assertEq(vault.totalAssets(), 0);
    }

    function test_TotalAssets_AfterDeposit() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, alice);
        assertEq(vault.totalAssets(), DEPOSIT_AMOUNT);
    }

    function test_MaxDeposit_Unlimited_WhenNotPaused() public view {
        assertEq(vault.maxDeposit(alice), type(uint256).max);
    }

    function test_MaxWithdraw_EqualsBalance() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, alice);
        assertEq(vault.maxWithdraw(alice), DEPOSIT_AMOUNT);
    }

    // access control roles

    function test_AccessControl_YieldManagerRole() public {
        bytes32 role = vault.YIELD_MANAGER_ROLE();
        assertTrue(vault.hasRole(role, admin));
        assertFalse(vault.hasRole(role, nobody));
    }

    function test_AccessControl_PauserRole() public {
        bytes32 role = vault.PAUSER_ROLE();
        assertTrue(vault.hasRole(role, admin));
        assertFalse(vault.hasRole(role, nobody));
    }

    function test_AccessControl_GrantRole_ThenDistributeYield() public {
        bytes32 role = vault.YIELD_MANAGER_ROLE();
        vm.prank(admin);
        vault.grantRole(role, nobody);

        asset.mint(address(vault), 100e18);
        vm.prank(nobody);
        vault.distributeYield(100e18); // should succeed now
        assertEq(vault.accruedYield(), 100e18);
    }

    function test_NewFeed_WorksAfterSet() public {
        MockAggregator newFeed = new MockAggregator(int256(3000e8), 8);
        vm.prank(admin);
        vault.setPriceFeed(address(newFeed));
        vm.prank(alice);
        uint256 shares = vault.deposit(DEPOSIT_AMOUNT, alice);
        assertGt(shares, 0);
    }

    // UUPS upgrade tests

    function test_UUPS_UpgradeByAdmin() public {
        // Deploy a new implementation
        YieldVault newImpl = new YieldVault();

        // Admin can upgrade
        vm.prank(admin);
        vault.upgradeToAndCall(address(newImpl), "");

        // Vault still works after upgrade
        vm.prank(alice);
        uint256 shares = vault.deposit(DEPOSIT_AMOUNT, alice);
        assertGt(shares, 0);
    }

    function test_UUPS_UpgradeRevert_Unauthorized() public {
        YieldVault newImpl = new YieldVault();

        vm.prank(nobody);
        vm.expectRevert();
        vault.upgradeToAndCall(address(newImpl), "");
    }

    function test_UUPS_StoragePreservedAfterUpgrade() public {
        // Deposit before upgrade
        vm.prank(alice);
        uint256 sharesBefore = vault.deposit(DEPOSIT_AMOUNT, alice);

        // Upgrade
        YieldVault newImpl = new YieldVault();
        vm.prank(admin);
        vault.upgradeToAndCall(address(newImpl), "");

        // Shares still there
        assertEq(vault.balanceOf(alice), sharesBefore);
        assertEq(vault.totalAssets(), DEPOSIT_AMOUNT);
    }
}
