// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {
    ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @title AMM
/// @notice Constant-product AMM (x·y=k) with 0.3% fee, LP tokens, slippage protection
contract AMM is ERC20, Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    uint256 public constant FEE_NUMERATOR = 997;
    uint256 public constant FEE_DENOMINATOR = 1000;
    uint256 public constant MINIMUM_LIQUIDITY = 1000;

    IERC20 public tokenA;
    IERC20 public tokenB;

    uint256 public reserveA;
    uint256 public reserveB;

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

    error InsufficientLiquidity();
    error InsufficientOutputAmount();
    error InsufficientInputAmount();
    error InvalidToken();
    error SlippageExceeded();
    error ZeroAmount();
    error KInvariantViolated();

    constructor(
        address _tokenA,
        address _tokenB,
        address _owner
    ) ERC20("AMM LP Token", "ALP") Ownable(_owner) {
        tokenA = IERC20(_tokenA);
        tokenB = IERC20(_tokenB);
    }

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

        uint256 totalSupply_ = totalSupply();
        if (totalSupply_ == 0) {
            liquidity = _sqrt(amountA * amountB) - MINIMUM_LIQUIDITY;
            _mint(address(0xdead), MINIMUM_LIQUIDITY);
        } else {
            liquidity = _min(
                (amountA * totalSupply_) / _reserveA,
                (amountB * totalSupply_) / _reserveB
            );
        }
        if (liquidity == 0) revert InsufficientLiquidity();

        reserveA = _reserveA + amountA;
        reserveB = _reserveB + amountB;

        tokenA.safeTransferFrom(msg.sender, address(this), amountA);
        tokenB.safeTransferFrom(msg.sender, address(this), amountB);
        _mint(msg.sender, liquidity);

        emit LiquidityAdded(msg.sender, amountA, amountB, liquidity);
        emit ReservesUpdated(reserveA, reserveB);
    }

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
        uint256 totalSupply_ = totalSupply();
        amountA = (liquidity * reserveA) / totalSupply_;
        amountB = (liquidity * reserveB) / totalSupply_;
        if (amountA < amountAMin || amountB < amountBMin)
            revert SlippageExceeded();
        if (amountA == 0 || amountB == 0) revert InsufficientLiquidity();
        reserveA -= amountA;
        reserveB -= amountB;
        _burn(msg.sender, liquidity);

        tokenA.safeTransfer(msg.sender, amountA);
        tokenB.safeTransfer(msg.sender, amountB);

        emit LiquidityRemoved(msg.sender, amountA, amountB, liquidity);
        emit ReservesUpdated(reserveA, reserveB);
    }

    function swap(
        address tokenIn,
        uint256 amountIn,
        uint256 amountOutMin
    ) external nonReentrant whenNotPaused returns (uint256 amountOut) {
        if (amountIn == 0) revert InsufficientInputAmount();
        bool aToB = tokenIn == address(tokenA);
        if (!aToB && tokenIn != address(tokenB)) revert InvalidToken();
        (uint256 reserveIn, uint256 reserveOut) = aToB
            ? (reserveA, reserveB)
            : (reserveB, reserveA);

        amountOut = getAmountOut(amountIn, reserveIn, reserveOut);
        if (amountOut < amountOutMin) revert SlippageExceeded();
        if (amountOut == 0) revert InsufficientOutputAmount();

        _verifyKInvariant(
            reserveIn + amountIn,
            reserveOut - amountOut,
            reserveIn,
            reserveOut
        );
        if (aToB) {
            reserveA += amountIn;
            reserveB -= amountOut;
        } else {
            reserveB += amountIn;
            reserveA -= amountOut;
        }

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        (aToB ? tokenB : tokenA).safeTransfer(msg.sender, amountOut);
        emit Swap(msg.sender, tokenIn, amountIn, amountOut);
        emit ReservesUpdated(reserveA, reserveB);
    }

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

    function _verifyKInvariant(
        uint256 newReserveIn,
        uint256 newReserveOut,
        uint256 oldReserveIn,
        uint256 oldReserveOut
    ) internal pure {
        assembly {
            let oldK := mul(oldReserveIn, oldReserveOut)
            if and(
                iszero(iszero(oldReserveIn)),
                iszero(eq(div(oldK, oldReserveIn), oldReserveOut))
            ) {
                mstore(0x00, shl(224, 0x8bdf6e9d))
                revert(0x00, 0x04)
            }
            let newK := mul(newReserveIn, newReserveOut)
            if and(
                iszero(iszero(newReserveIn)),
                iszero(eq(div(newK, newReserveIn), newReserveOut))
            ) {
                mstore(0x00, shl(224, 0x8bdf6e9d))
                revert(0x00, 0x04)
            }
            if lt(newK, oldK) {
                mstore(0x00, shl(224, 0x8bdf6e9d))
                revert(0x00, 0x04)
            }
        }
    }

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

    function pause() external onlyOwner {
        _pause();
    }
    function unpause() external onlyOwner {
        _unpause();
    }
}
