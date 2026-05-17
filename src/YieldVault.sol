// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    ERC4626Upgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {
    ERC20Upgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    AccessControlUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {
    ReentrancyGuard as ReentrancyGuardUpgradeable
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {
    PausableUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {
    UUPSUpgradeable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    Initializable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPriceFeed} from "./interfaces/IPriceFeed.sol";

/// @title YieldVault
/// @notice ERC-4626 tokenized yield vault. UUPS upgradeable.
contract YieldVault is
    Initializable,
    ERC4626Upgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using Math for uint256;

    bytes32 public constant YIELD_MANAGER_ROLE =
        keccak256("YIELD_MANAGER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    IPriceFeed public priceFeed;
    uint256 public maxStaleness;
    uint256 public minPrice;

    bool public bypassPriceCheck;
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
        __Pausable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(YIELD_MANAGER_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);

        priceFeed = IPriceFeed(_priceFeed);
        maxStaleness = _maxStaleness;
        minPrice = _minPrice;
        bypassPriceCheck = true;
    }

    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    function deposit(
        uint256 assets,
        address receiver
    ) public override nonReentrant whenNotPaused returns (uint256 shares) {
        _checkPrice();
        shares = super.deposit(assets, receiver);
    }

    function mint(
        uint256 shares,
        address receiver
    ) public override nonReentrant whenNotPaused returns (uint256 assets) {
        _checkPrice();
        assets = super.mint(shares, receiver);
    }

    function withdraw(
        uint256 assets,
        address receiver,
        address owner_
    ) public override nonReentrant whenNotPaused returns (uint256 shares) {
        shares = super.withdraw(assets, receiver, owner_);
    }

    function redeem(
        uint256 shares,
        address receiver,
        address owner_
    ) public override nonReentrant whenNotPaused returns (uint256 assets) {
        assets = super.redeem(shares, receiver, owner_);
    }

    function distributeYield(
        uint256 amount
    ) external onlyRole(YIELD_MANAGER_ROLE) {
        accruedYield += amount;
        emit YieldDistributed(amount);
    }

    function setBypassPriceCheck(
        bool status
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        bypassPriceCheck = status;
        emit BypassPriceCheckUpdated(status);
    }

    function setPriceFeed(
        address newFeed
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newFeed == address(0)) revert InvalidFeed();
        priceFeed = IPriceFeed(newFeed);
        emit PriceFeedUpdated(newFeed);
    }

    function setMaxStaleness(
        uint256 newMax
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        maxStaleness = newMax;
        emit MaxStalenessUpdated(newMax);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

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

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
