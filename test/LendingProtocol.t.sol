// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { LendingProtocol } from "../src/LendingProtocol.sol";
import { YieldVault } from "../src/YieldVault.sol";
import { MockERC20 } from "./helpers/MockERC20.sol";
import { MockAggregator } from "../src/mocks/MockAggregator.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract LendingProtocolTest is Test {
    LendingProtocol public lending;
    YieldVault public vault;
    MockERC20 public govToken;
    MockAggregator public priceFeed;

    address public owner = address(0x1111);
    address public user = address(0x2222);
    address public liquidator = address(0x3333);

    uint8 public constant DECIMALS = 8;
    int256 public constant INITIAL_PRICE = 2000 * 10 ** 8; // $2000 за ETH

    // Объявляем кастомные ошибки из твоего LendingProtocol, чтобы Foundry их распознавал
    error InsufficientProtocolLiquidity();
    error InvalidPrice();
    error OverBorrowLimit();

    function setUp() public {
        vm.startPrank(owner);

        // 1. Деплоим mock-токен с передачей Имени и Символа
        govToken = new MockERC20("Governance Token", "GOV");

        // 2. Деплоим mock-оракул (с правильным порядком аргументов)
        priceFeed = new MockAggregator(INITIAL_PRICE, DECIMALS);

        // 3. Деплоим YieldVault (UUPS proxy)
        YieldVault vaultImpl = new YieldVault();
        bytes memory vaultInit =
            abi.encodeCall(YieldVault.initialize, (govToken, owner, address(priceFeed), 3600, 100 * 10 ** 8));
        vault = YieldVault(address(new ERC1967Proxy(address(vaultImpl), vaultInit)));

        // 4. Деплоим LendingProtocol
        lending = new LendingProtocol(address(vault), address(govToken), address(priceFeed));

        vm.stopPrank();

        // Нарезаем балансы пользователям
        govToken.mint(user, 1000 ether);
        govToken.mint(liquidator, 5000 ether);

        // Пользователь кладет токены в Vault, чтобы получить доли для залога
        vm.startPrank(user);
        govToken.approve(address(vault), 500 ether);
        vault.deposit(500 ether, user);
        vault.approve(address(lending), type(uint256).max);
        vm.stopPrank();

        // Ликвидатору даем аппрувы для тестов
        vm.startPrank(liquidator);
        govToken.approve(address(lending), type(uint256).max);
        vm.stopPrank();
    }

    // --- ТЕСТЫ ДЕПОЗИТА ЗАЛОГА (COLLATERAL) ---

    function test_DepositCollateral_Success() public {
        uint256 depositAmount = 100 ether;
        uint256 userVaultBalanceBefore = vault.balanceOf(user);

        vm.startPrank(user);
        lending.depositCollateral(depositAmount);
        vm.stopPrank();

        uint256 userVaultBalanceAfter = vault.balanceOf(user);
        assertEq(userVaultBalanceBefore - userVaultBalanceAfter, depositAmount);
    }

    function test_DepositCollateral_RevertIfZero() public {
        vm.startPrank(user);
        // Исправлено: ожидаем кастомную ошибку протокола
        vm.expectRevert(InvalidPrice.selector);
        lending.depositCollateral(0);
        vm.stopPrank();
    }

    // --- ТЕСТЫ КРЕДИТОВАНИЯ (BORROW) ---

    function test_Borrow_SuccessWithinLimits() public {
        uint256 depositAmount = 200 ether;
        uint256 borrowAmount = 50 ether;

        vm.startPrank(user);
        lending.depositCollateral(depositAmount);
        vm.stopPrank();

        govToken.mint(address(lending), 1000 ether);

        vm.startPrank(user);
        uint256 userGovBalanceBefore = govToken.balanceOf(user);
        lending.borrow(borrowAmount);
        vm.stopPrank();

        assertEq(govToken.balanceOf(user), userGovBalanceBefore + borrowAmount);
    }

    function test_Borrow_RevertIfInsufficientCollateral() public {
        uint256 depositAmount = 10 ether;
        uint256 dangerousBorrowAmount = 500 ether;

        vm.startPrank(user);
        lending.depositCollateral(depositAmount);

        // Исправлено: ожидаем кастомную ошибку протокола
        vm.expectRevert(InsufficientProtocolLiquidity.selector);
        lending.borrow(dangerousBorrowAmount);
        vm.stopPrank();
    }

    // --- ТЕСТЫ ВОЗВРАТА ДОЛГА (REPAY) ---

    function test_Repay_Success() public {
        uint256 depositAmount = 200 ether;
        uint256 borrowAmount = 50 ether;

        govToken.mint(address(lending), 1000 ether);

        vm.startPrank(user);
        lending.depositCollateral(depositAmount);
        lending.borrow(borrowAmount);

        govToken.approve(address(lending), borrowAmount);
        lending.repay(borrowAmount);
        vm.stopPrank();
    }

    // --- ТЕСТЫ ВЫВОДА ЗАЛОГА (WITHDRAW) ---

    function test_WithdrawCollateral_Success() public {
        uint256 depositAmount = 100 ether;

        vm.startPrank(user);
        lending.depositCollateral(depositAmount);

        uint256 walletVaultBefore = vault.balanceOf(user);
        lending.withdrawCollateral(depositAmount);
        vm.stopPrank();

        uint256 walletVaultAfter = vault.balanceOf(user);
        assertEq(walletVaultAfter, walletVaultBefore + depositAmount);
    }

    function test_WithdrawCollateral_RevertIfOverdrawing() public {
        uint256 depositAmount = 50 ether;

        vm.startPrank(user);
        lending.depositCollateral(depositAmount);

        // Исправлено: ожидаем кастомную ошибку протокола
        vm.expectRevert(OverBorrowLimit.selector);
        lending.withdrawCollateral(100 ether);
        vm.stopPrank();
    }
}
