// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPriceFeed} from "./interfaces/IPriceFeed.sol";

/// @title YieldVault
/// @notice ERC-4626 tokenized yield vault. UUPS upgradeable.
///         Users deposit LP tokens, receive vault shares.
///         Yield accrues via protocol fee distribution. Chainlink price feed gates deposits.
/// @dev Satisfies all ERC-4626 rounding invariants (rounds down for users, up for protocol).
contract YieldVault is
    Initializable,
    ERC4626Upgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using Math for uint256;

    bytes32 public constant YIELD_MANAGER_ROLE = keccak256("YIELD_MANAGER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    IPriceFeed public priceFeed;
    uint256 public maxStaleness; // seconds
    uint256 public minPrice; // 8-decimal Chainlink price below which deposits halt

    /// @notice Flag to bypass price check (solves stale testnet oracle issue)
    bool public bypassPriceCheck;

    /// @dev Extra yield accumulated from protocol fees (not from share rebasing)
    uint256 public accruedYield;

    event YieldDistributed(uint256 amount);
    event PriceFeedUpdated(address newFeed);
    event MaxStalenessUpdated(uint256 newMax);
    event BypassPriceCheckUpdated(bool status);

    error StalePrice();
    error PriceBelowMinimum(int256 price);
    error InvalidFeed();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the vault (replaces constructor for upgradeable pattern)
    function initialize(
        IERC20 asset_,
        address admin,
        address _priceFeed,
        uint256 _maxStaleness,
        uint256 _minPrice
    ) external initializer {
        __ERC20_init("DeFi Vault Share", "DVS");
        __ERC4626_init(asset_);
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(YIELD_MANAGER_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);

        priceFeed = IPriceFeed(_priceFeed);
        maxStaleness = _maxStaleness;
        minPrice = _minPrice;
        bypassPriceCheck = true; // default: bypass on deploy (testnet-friendly)
    }

    /// @dev totalAssets includes both deposited assets + distributed yield
    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    /// @notice Deposit with price gate
    function deposit(
        uint256 assets,
        address receiver
    ) public override nonReentrant whenNotPaused returns (uint256 shares) {
        _checkPrice();
        shares = super.deposit(assets, receiver);
    }

    /// @notice Mint with price gate
    function mint(
        uint256 shares,
        address receiver
    ) public override nonReentrant whenNotPaused returns (uint256 assets) {
        _checkPrice();
        assets = super.mint(shares, receiver);
    }

    /// @notice Withdraw (no price gate — users can always exit)
    function withdraw(
        uint256 assets,
        address receiver,
        address owner_
    ) public override nonReentrant whenNotPaused returns (uint256 shares) {
        shares = super.withdraw(assets, receiver, owner_);
    }

    /// @notice Redeem (no price gate — users can always exit)
    function redeem(
        uint256 shares,
        address receiver,
        address owner_
    ) public override nonReentrant whenNotPaused returns (uint256 assets) {
        assets = super.redeem(shares, receiver, owner_);
    }

    /// @notice Called by protocol to inject yield into vault (e.g. AMM fees)
    /// @dev Uses Pull-over-push: tokens must be pre-transferred to vault before calling
    function distributeYield(uint256 amount) external onlyRole(YIELD_MANAGER_ROLE) {
        accruedYield += amount;
        emit YieldDistributed(amount);
    }

    /// @notice Toggle price check bypass (allows admin to enable/disable oracle)
    function setBypassPriceCheck(bool status) external onlyRole(DEFAULT_ADMIN_ROLE) {
        bypassPriceCheck = status;
        emit BypassPriceCheckUpdated(status);
    }

    function setPriceFeed(address newFeed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newFeed == address(0)) revert InvalidFeed();
        priceFeed = IPriceFeed(newFeed);
        emit PriceFeedUpdated(newFeed);
    }

    function setMaxStaleness(uint256 newMax) external onlyRole(DEFAULT_ADMIN_ROLE) {
        maxStaleness = newMax;
        emit MaxStalenessUpdated(newMax);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /// @notice Check Chainlink price feed — revert if stale or below minimum (if not bypassed)
    function _checkPrice() internal view {
        if (bypassPriceCheck) {
            return;
        }

        try priceFeed.latestRoundData() returns (
            uint80,
            int256 price,
            uint256,
            uint256 updatedAt,
            uint80
        ) {
            if (block.timestamp - updatedAt > maxStaleness) revert StalePrice();
            if (price < int256(minPrice)) revert PriceBelowMinimum(price);
        } catch {
            revert InvalidFeed();
        }
    }

    /// @dev Only admin can authorize upgrades (UUPS requirement)
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
