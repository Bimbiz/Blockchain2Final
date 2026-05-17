// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMM} from "./AMM.sol";

/// @title AMMFactory
/// @notice Deploys AMM pairs using both CREATE and CREATE2
/// @dev Design pattern: Factory pattern
contract AMMFactory {
    address public immutable owner;

    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;

    event PairCreated(
        address indexed tokenA,
        address indexed tokenB,
        address pair,
        uint256 pairIndex,
        bool deterministicCreate2
    );

    error PairExists();
    error IdenticalTokens();
    error ZeroAddress();

    constructor(address _owner) {
        owner = _owner;
    }

    /// @notice Deploy pair with CREATE (non-deterministic address)
    function createPair(
        address tokenA,
        address tokenB
    ) external returns (address pair) {
        _validateTokens(tokenA, tokenB);
        (address token0, address token1) = _sortTokens(tokenA, tokenB);

        // Прямой деплой через CREATE
        pair = address(new AMM(token0, token1, owner));

        _registerPair(token0, token1, pair, false);
    }

    /// @notice Deploy pair with CREATE2 (deterministic address, pre-computable)
    /// @param salt Caller-supplied salt for address derivation
    function createPair2(
        address tokenA,
        address tokenB,
        bytes32 salt
    ) external returns (address pair) {
        _validateTokens(tokenA, tokenB);
        (address token0, address token1) = _sortTokens(tokenA, tokenB);

        // Deploy using CREATE2 with inline assembly for gas efficiency
        bytes memory bytecode = abi.encodePacked(
            type(AMM).creationCode,
            abi.encode(token0, token1, owner)
        );

        bytes32 create2Salt = keccak256(
            abi.encodePacked(msg.sender, token0, token1, salt)
        );

        assembly {
            pair := create2(
                0,
                add(bytecode, 0x20),
                mload(bytecode),
                create2Salt
            )

            if iszero(extcodesize(pair)) {
                revert(0, 0)
            }
        }

        _registerPair(token0, token1, pair, true);
    }

    /// @notice Pre-compute the CREATE2 address without deploying
    function computePairAddress(
        address tokenA,
        address tokenB,
        bytes32 salt,
        address deployer
    ) external view returns (address) {
        (address token0, address token1) = _sortTokens(tokenA, tokenB);

        bytes memory bytecode = abi.encodePacked(
            type(AMM).creationCode,
            abi.encode(token0, token1, owner)
        );

        bytes32 create2Salt = keccak256(
            abi.encodePacked(deployer, token0, token1, salt)
        );

        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                address(this),
                create2Salt,
                keccak256(bytecode)
            )
        );

        return address(uint160(uint256(hash)));
    }

    function allPairsLength() external view returns (uint256) {
        return allPairs.length;
    }

    // Internal

    function _validateTokens(address tokenA, address tokenB) internal view {
        if (tokenA == tokenB) revert IdenticalTokens();
        if (tokenA == address(0) || tokenB == address(0)) revert ZeroAddress();
        (address t0, address t1) = _sortTokens(tokenA, tokenB);
        if (getPair[t0][t1] != address(0)) revert PairExists();
    }

    function _sortTokens(
        address tokenA,
        address tokenB
    ) internal pure returns (address, address) {
        return tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    function _registerPair(
        address token0,
        address token1,
        address pair,
        bool isDeterministic
    ) internal {
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair;
        allPairs.push(pair);
        emit PairCreated(
            token0,
            token1,
            pair,
            allPairs.length,
            isDeterministic
        );
    }
}
