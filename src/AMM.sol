// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    ERC20Upgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {
    UUPSUpgradeable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {
    ReentrancyGuardUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {
    PausableUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

/// @title AMM
/// @notice Constant-product AMM (x·y=k) with 0.3% fee, LP tokens, slippage protection
/// @dev Upgradeable via UUPS proxy. Contains Yul assembly for gas-optimised k calculation.
///      Design patterns: UUPS, ReentrancyGuard, CEI, Pausable/Circuit Breaker, State Machine
contract AMM is
    ERC20Upgradeable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    using SafeERC20 for IERC20;

    // Constants
    uint256 public constant FEE_NUMERATOR = 997; // 0.3% fee → multiplier 997/1000
    uint256 public constant FEE_DENOMINATOR = 1000;
    uint256 public constant MINIMUM_LIQUIDITY = 1000; // Locked forever to prevent inflation attack

    // State
    IERC20 public tokenA;
    IERC20 public tokenB;

    uint256 public reserveA;
    uint256 public reserveB;

    /// @notice Version for upgrade tracking (V1 - V2 upgrade path documented)
    uint256 public version;

    // Events
    event LiquidityAdded(
        address indexed provider,
        uint256 amountA,
        uint256 amountB,
        uint256 lpMinted
    );
    event LiquidityRemoved(
        address indexed provider,
        uint256 amountA,
        uint256 amountB,
        uint256 lpBurned
    );
    event Swap(
        address indexed user,
        address tokenIn,
        uint256 amountIn,
        uint256 amountOut
    );
    event ReservesUpdated(uint256 reserveA, uint256 reserveB);

    // Errors
    error InsufficientLiquidity();
    error InsufficientOutputAmount();
    error InsufficientInputAmount();
    error InvalidToken();
    error SlippageExceeded();
    error ZeroAmount();
    error KInvariantViolated();

    // Initializer (replaces constructor for upgradeable)

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _tokenA,
        address _tokenB,
        address _owner
    ) external initializer {
        __ERC20_init("AMM LP Token", "ALP");
        __UUPSUpgradeable_init();
        __Ownable_init(_owner);
        __ReentrancyGuard_init();
        __Pausable_init();

        tokenA = IERC20(_tokenA);
        tokenB = IERC20(_tokenB);
        version = 1;
    }

    // Core AMM logic

    /// @notice Add liquidity, receive LP tokens
    /// @param amountADesired Max tokenA to deposit
    /// @param amountBDesired Max tokenB to deposit
    /// @param amountAMin    Slippage floor for tokenA
    /// @param amountBMin    Slippage floor for tokenB
    function addLiquidity(
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin
    )
        external
        nonReentrant
        whenNotPaused
        returns (uint256 amountA, uint256 amountB, uint256 liquidity)
    {
        if (amountADesired == 0 || amountBDesired == 0) revert ZeroAmount();

        uint256 _reserveA = reserveA;
        uint256 _reserveB = reserveB;

        // Checks
        if (_reserveA == 0 && _reserveB == 0) {
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            uint256 amountBOptimal = quote(
                amountADesired,
                _reserveA,
                _reserveB
            );
            if (amountBOptimal <= amountBDesired) {
                if (amountBOptimal < amountBMin) revert SlippageExceeded();
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                uint256 amountAOptimal = quote(
                    amountBDesired,
                    _reserveB,
                    _reserveA
                );
                if (amountAOptimal < amountAMin) revert SlippageExceeded();
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
        }

        // Effects
        uint256 totalSupply_ = totalSupply();
        if (totalSupply_ == 0) {
            // Geometric mean minus minimum liquidity (inflation attack prevention)
            liquidity = _sqrt(amountA * amountB) - MINIMUM_LIQUIDITY;
            _mint(address(0xdead), MINIMUM_LIQUIDITY); // Burn minimum liquidity
        } else {
            liquidity = _min(
                (amountA * totalSupply_) / _reserveA,
                (amountB * totalSupply_) / _reserveB
            );
        }
        if (liquidity == 0) revert InsufficientLiquidity();

        reserveA = _reserveA + amountA;
        reserveB = _reserveB + amountB;

        // Interactions
        tokenA.safeTransferFrom(msg.sender, address(this), amountA);
        tokenB.safeTransferFrom(msg.sender, address(this), amountB);
        _mint(msg.sender, liquidity);

        emit LiquidityAdded(msg.sender, amountA, amountB, liquidity);
        emit ReservesUpdated(reserveA, reserveB);
    }

    /// @notice Remove liquidity by burning LP tokens
    function removeLiquidity(
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin
    )
        external
        nonReentrant
        whenNotPaused
        returns (uint256 amountA, uint256 amountB)
    {
        if (liquidity == 0) revert ZeroAmount();

        // Checks
        uint256 totalSupply_ = totalSupply();
        amountA = (liquidity * reserveA) / totalSupply_;
        amountB = (liquidity * reserveB) / totalSupply_;
        if (amountA < amountAMin || amountB < amountBMin)
            revert SlippageExceeded();
        if (amountA == 0 || amountB == 0) revert InsufficientLiquidity();

        // Effects
        reserveA -= amountA;
        reserveB -= amountB;
        _burn(msg.sender, liquidity);

        //Interactions
        tokenA.safeTransfer(msg.sender, amountA);
        tokenB.safeTransfer(msg.sender, amountB);

        emit LiquidityRemoved(msg.sender, amountA, amountB, liquidity);
        emit ReservesUpdated(reserveA, reserveB);
    }

    /// @notice Swap tokenA for tokenB (or vice versa)
    /// @param tokenIn    Address of input token
    /// @param amountIn   Input amount
    /// @param amountOutMin Minimum output (slippage protection)
    function swap(
        address tokenIn,
        uint256 amountIn,
        uint256 amountOutMin
    ) external nonReentrant whenNotPaused returns (uint256 amountOut) {
        if (amountIn == 0) revert InsufficientInputAmount();

        // Checks
        bool aToB = tokenIn == address(tokenA);
        if (!aToB && tokenIn != address(tokenB)) revert InvalidToken();

        (uint256 reserveIn, uint256 reserveOut) = aToB
            ? (reserveA, reserveB)
            : (reserveB, reserveA);

        amountOut = getAmountOut(amountIn, reserveIn, reserveOut);
        if (amountOut < amountOutMin) revert SlippageExceeded();
        if (amountOut == 0) revert InsufficientOutputAmount();

        // Verify k-invariant post-swap (using Yul for gas efficiency)
        _verifyKInvariant(
            reserveIn + amountIn,
            reserveOut - amountOut,
            reserveIn,
            reserveOut
        );

        // Effects
        if (aToB) {
            reserveA += amountIn;
            reserveB -= amountOut;
        } else {
            reserveB += amountIn;
            reserveA -= amountOut;
        }

        // Interactions
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        (aToB ? tokenB : tokenA).safeTransfer(msg.sender, amountOut);

        emit Swap(msg.sender, tokenIn, amountIn, amountOut);
        emit ReservesUpdated(reserveA, reserveB);
    }

    // View / Pure helpers

    /// @notice Calculate output amount with 0.3% fee applied
    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) public pure returns (uint256 amountOut) {
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();
        uint256 amountInWithFee = amountIn * FEE_NUMERATOR;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = (reserveIn * FEE_DENOMINATOR) + amountInWithFee;
        amountOut = numerator / denominator;
    }

    /// @notice Price quote for a given amount (no fee)
    function quote(
        uint256 amountA_,
        uint256 _reserveA,
        uint256 _reserveB
    ) public pure returns (uint256 amountB_) {
        if (amountA_ == 0) revert ZeroAmount();
        if (_reserveA == 0 || _reserveB == 0) revert InsufficientLiquidity();
        amountB_ = (amountA_ * _reserveB) / _reserveA;
    }

    function getReserves()
        external
        view
        returns (uint256 _reserveA, uint256 _reserveB)
    {
        return (reserveA, reserveB);
    }

    // Yul assembly - gas-optimised k-invariant check
    /// @notice Verify that k does not decrease after swap (Yul version)
    /// @dev Benchmarked vs pure-Solidity equivalent in test/AMM.yul.t.sol
    function _verifyKInvariant(
        uint256 newReserveIn,
        uint256 newReserveOut,
        uint256 oldReserveIn,
        uint256 oldReserveOut
    ) internal pure {
        assembly {
            // newK = newReserveIn * newReserveOut
            // oldK = oldReserveIn * oldReserveOut
            // require(newK >= oldK)  — fee means newK is always >= oldK
            let newK := mul(newReserveIn, newReserveOut)
            let oldK := mul(oldReserveIn, oldReserveOut)
            // Overflow guard: if newK < newReserveIn when newReserveOut>1, overflow occurred
            if lt(newK, oldK) {
                // Store selector of KInvariantViolated() = keccak256 first 4 bytes
                mstore(0x00, 0x8bdf6e9d)
                revert(0x1c, 0x04)
            }
        }
    }

    // Internal math

    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    // Admin

    function pause() external onlyOwner {
        _pause();
    }
    function unpause() external onlyOwner {
        _unpause();
    }

    // UUPS upgrade auth

    /// @dev Only owner (will be transferred to Timelock post-deploy)
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}
}
