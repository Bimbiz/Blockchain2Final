// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPriceFeed} from "../interfaces/IPriceFeed.sol";

/// @notice Controllable mock Chainlink price feed for tests
contract MockAggregator is IPriceFeed {
    int256 public price;
    uint256 public updatedAt;
    uint80 public roundId;
    uint8 public override decimals;

    constructor(int256 _initialPrice, uint8 _decimals) {
        price = _initialPrice;
        updatedAt = block.timestamp;
        decimals = _decimals;
        roundId = 1;
    }

    function setPrice(int256 _price) external {
        price = _price;
        updatedAt = block.timestamp;
        roundId++;
    }

    /// @notice Set a stale timestamp (for staleness tests)
    function setUpdatedAt(uint256 _updatedAt) external {
        updatedAt = _updatedAt;
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (roundId, price, updatedAt, updatedAt, roundId);
    }
}
