// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, console2 } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AMM } from "../src/AMM.sol";
import { YieldVault } from "../src/YieldVault.sol";
import { IPriceFeed } from "../src/interfaces/IPriceFeed.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract ForkTests is Test {
    address constant CHAINLINK_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant UNISWAP_V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address constant USDC_WHALE = 0x47ac0Fb4F2D84898e4D9E7b4DaB3C24507a6D503;

    uint256 mainnetFork;

    function setUp() public {
        mainnetFork = vm.createFork(vm.envString("ETH_RPC_URL"), 19000000);
        vm.selectFork(mainnetFork);
    }

    function test_Fork_Chainlink_ETH_USD_PriceFeed() public {
        IPriceFeed feed = IPriceFeed(CHAINLINK_ETH_USD);
        (uint80 roundId, int256 price,, uint256 updatedAt, uint80 answeredInRound) = feed.latestRoundData();

        assertGt(price, 0, "Price must be positive");
        assertLt(uint256(price), 1_000_000e8, "Price below 1M USD (sanity)");
        assertGt(updatedAt, 0, "Must have been updated");
        assertLe(answeredInRound, roundId, "Answered in valid round");
    }

    function test_Fork_USDC_RealToken_Interaction() public {
        IERC20 usdc = IERC20(USDC);
        uint256 whaleBalance = usdc.balanceOf(USDC_WHALE);
        assertGt(whaleBalance, 1_000e6, "Whale must have at least 1000 USDC");

        address recipient = makeAddr("recipient");

        vm.prank(USDC_WHALE);
        usdc.transfer(recipient, 10_000e6);

        assertEq(usdc.balanceOf(recipient), 10_000e6);
    }

    function test_Fork_USDC_DepositToVault_Success() public {
        IPriceFeed feed = IPriceFeed(CHAINLINK_ETH_USD);
        (,,, uint256 updatedAt,) = feed.latestRoundData();

        vm.warp(updatedAt + 10);

        YieldVault vaultImpl1 = new YieldVault();
        bytes memory init1 = abi.encodeCall(
            YieldVault.initialize, (IERC20(USDC), makeAddr("vaultAdmin"), CHAINLINK_ETH_USD, 7200, 1e8)
        );
        YieldVault vault = YieldVault(address(new ERC1967Proxy(address(vaultImpl1), init1)));

        uint256 depositAmount = 10_000e6;
        vm.prank(USDC_WHALE);
        IERC20(USDC).transfer(address(this), depositAmount);

        IERC20(USDC).approve(address(vault), depositAmount);

        uint256 shares = vault.deposit(depositAmount, address(this));
        assertGt(shares, 0, "Shares should be minted");
        assertEq(vault.totalAssets(), depositAmount, "Assets mismatch");
    }

    function test_Fork_USDC_DepositToVault_RevertIfStale() public {
        IPriceFeed feed = IPriceFeed(CHAINLINK_ETH_USD);
        (,,, uint256 updatedAt,) = feed.latestRoundData();

        address staleAdmin = makeAddr("staleAdmin");
        YieldVault vaultImpl2 = new YieldVault();
        bytes memory init2 =
            abi.encodeCall(YieldVault.initialize, (IERC20(USDC), staleAdmin, CHAINLINK_ETH_USD, 7200, 1e8));
        YieldVault vault2 = YieldVault(address(new ERC1967Proxy(address(vaultImpl2), init2)));

        // Disable bypass so staleness check is active
        vm.prank(staleAdmin);
        vault2.setBypassPriceCheck(false);

        uint256 depositAmount = 10_000e6;
        vm.prank(USDC_WHALE);
        IERC20(USDC).transfer(address(this), depositAmount);
        IERC20(USDC).approve(address(vault2), depositAmount);

        vm.warp(updatedAt + 7201);

        vm.expectRevert(YieldVault.StalePrice.selector);
        vault2.deposit(depositAmount, address(this));
    }

    function test_Fork_UniswapV2_RouterExists_AndGetAmountsOut() public {
        bytes memory code = UNISWAP_V2_ROUTER.code;
        assertGt(code.length, 0, "UniswapV2 router must be deployed");

        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = USDC;

        bytes memory callData = abi.encodeWithSignature("getAmountsOut(uint256,address[])", 1e18, path);
        (bool success, bytes memory result) = UNISWAP_V2_ROUTER.staticcall(callData);
        assertTrue(success, "getAmountsOut must succeed");

        uint256[] memory amounts = abi.decode(result, (uint256[]));
        assertGt(amounts[1], 100e6, "1 WETH must be worth >$100");
    }

    function test_Fork_UniswapV2_CompareWithOurAMM_Pricing() public {
        address[] memory path = new address[](2);
        path[0] = USDC;
        path[1] = WETH;

        bytes memory callData = abi.encodeWithSignature("getAmountsOut(uint256,address[])", 1000e6, path);
        (bool success, bytes memory result) = UNISWAP_V2_ROUTER.staticcall(callData);
        assertTrue(success);
        uint256[] memory amounts = abi.decode(result, (uint256[]));
        uint256 uniWETHOut = amounts[1];

        AMM myAmm = new AMM(USDC, WETH, address(this));

        uint256 reserveUSDC = 50_000_000e6;
        uint256 reserveWETH = 15_000e18;

        deal(USDC, address(myAmm), reserveUSDC);
        deal(WETH, address(myAmm), reserveWETH);

        uint256 ourWETHOut = myAmm.getAmountOut(1000e6, reserveUSDC, reserveWETH);

        assertGt(ourWETHOut, 0, "Our AMM formula failed");

        console2.log("Uniswap V2 output for 1000 USDC:", uniWETHOut);
        console2.log("Our AMM output with mock reserves:", ourWETHOut);
    }
}
