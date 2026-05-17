// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPriceFeed} from "./interfaces/IPriceFeed.sol";

/// @title LendingProtocol
/// @notice Позволяет пользователям вносить акции YieldVault (DVS) в качестве залога и занимать TokenB.
/// @dev Интегрировано с Chainlink Price Feeds для проверки условий ликвидации и LTV.
contract LendingProtocol is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable collateralToken;
    IERC20 public immutable borrowToken;
    IPriceFeed public immutable priceFeed;

    uint256 public constant LTV = 75;
    uint256 public constant PRICE_STALENESS_THRESHOLD = 3600;

    struct UserPosition {
        uint256 collateralAmount;
        uint256 borrowedAmount;
    }

    mapping(address => UserPosition) public positions;

    event CollateralDeposited(address indexed user, uint256 amount);
    event CollateralWithdrawn(address indexed user, uint256 amount);
    event AssetBorrowed(address indexed user, uint256 amount);
    event AssetRepaid(address indexed user, uint256 amount);

    error StalePrice();
    error InvalidPrice();
    error OverBorrowLimit();
    error InsufficientProtocolLiquidity();
    error RepayAmountOverflow();

    constructor(address _collateral, address _borrowToken, address _priceFeed) Ownable(msg.sender) {
        collateralToken = IERC20(_collateral);
        borrowToken = IERC20(_borrowToken);
        priceFeed = IPriceFeed(_priceFeed);
    }

    /// @notice Чтение цены из Chainlink с валидацией таймстампа (Требование безопасности проекта)
    function getLatestPrice() public view returns (uint256) {
        (, int256 price, , uint256 updatedAt, ) = priceFeed.latestRoundData();
        if (updatedAt == 0 || block.timestamp - updatedAt > PRICE_STALENESS_THRESHOLD) revert StalePrice();
        if (price <= 0) revert InvalidPrice();
        return uint256(price);
    }

    /// @notice Депозит акций ERC-4626 в качестве обеспечения
    function depositCollateral(uint256 _amount) external nonReentrant {
        if (_amount == 0) revert InvalidPrice();

        positions[msg.sender].collateralAmount += _amount;

        emit CollateralDeposited(msg.sender, _amount);
        collateralToken.safeTransferFrom(msg.sender, address(this), _amount);
    }

    /// @notice Займ активов под залог обеспечения с проверкой LTV
    function borrow(uint256 _borrowAmount) external nonReentrant {
        if (_borrowAmount == 0) revert InvalidPrice();
        UserPosition storage position = positions[msg.sender];

        uint256 assetPrice = getLatestPrice();
        uint256 collateralValue = (position.collateralAmount * assetPrice) / 10**8;
        uint256 maxBorrowAllowed = (collateralValue * LTV) / 100;

        if (position.borrowedAmount + _borrowAmount > maxBorrowAllowed) revert OverBorrowLimit();
        if (borrowToken.balanceOf(address(this)) < _borrowAmount) revert InsufficientProtocolLiquidity();

        position.borrowedAmount += _borrowAmount;

        emit AssetBorrowed(msg.sender, _borrowAmount);
        borrowToken.safeTransfer(msg.sender, _borrowAmount);
    }

    /// @notice Погашение долга
    function repay(uint256 _repayAmount) external nonReentrant {
        UserPosition storage position = positions[msg.sender];
        if (_repayAmount > position.borrowedAmount) revert RepayAmountOverflow();

        position.borrowedAmount -= _repayAmount;

        emit AssetRepaid(msg.sender, _repayAmount);
        borrowToken.safeTransferFrom(msg.sender, address(this), _repayAmount);
    }

    /// @notice Вывод обеспечения (разрешен только если позиция остается избыточно обеспеченной)
    function withdrawCollateral(uint256 _amount) external nonReentrant {
        UserPosition storage position = positions[msg.sender];
        if (_amount > position.collateralAmount) revert OverBorrowLimit();

        uint256 assetPrice = getLatestPrice();
        uint256 remainingCollateralValue = ((position.collateralAmount - _amount) * assetPrice) / 10**8;
        uint256 maxBorrowAllowed = (remainingCollateralValue * LTV) / 100;

        if (position.borrowedAmount > maxBorrowAllowed) revert OverBorrowLimit();

        position.collateralAmount -= _amount;

        emit CollateralWithdrawn(msg.sender, _amount);
        collateralToken.safeTransfer(msg.sender, _amount);
    }
}