// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {
    ERC721Enumerable
} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title LPPositionNFT
/// @notice ERC-721 NFT representing an LP position in a specific AMM pair.
///         Minted when user adds liquidity, burned when liquidity is removed.
contract LPPositionNFT is ERC721Enumerable, AccessControl {
    using Strings for uint256;

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    uint256 private _nextTokenId;
    string private _baseTokenURI;

    struct PositionInfo {
        address pair;
        uint256 lpAmount;
        uint256 mintedAt;
    }

    mapping(uint256 => PositionInfo) public positions;

    event PositionMinted(
        uint256 indexed tokenId,
        address indexed owner,
        address pair,
        uint256 lpAmount
    );
    event PositionBurned(uint256 indexed tokenId, address indexed owner);

    error NotOwnerOrApproved();

    constructor(
        address admin,
        string memory baseURI
    ) ERC721("LP Position", "LPP") {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MINTER_ROLE, admin);
        _baseTokenURI = baseURI;
    }

    /// @notice Mint an LP position NFT (called by AMM/vault on addLiquidity)
    function mintPosition(
        address to,
        address pair,
        uint256 lpAmount
    ) external onlyRole(MINTER_ROLE) returns (uint256 tokenId) {
        tokenId = _nextTokenId++;
        positions[tokenId] = PositionInfo({
            pair: pair,
            lpAmount: lpAmount,
            mintedAt: block.timestamp
        });
        _safeMint(to, tokenId);
        emit PositionMinted(tokenId, to, pair, lpAmount);
    }

    /// @notice Burn a position NFT (called on removeLiquidity)
    function burnPosition(uint256 tokenId) external onlyRole(MINTER_ROLE) {
        address owner = ownerOf(tokenId);
        _burn(tokenId);
        delete positions[tokenId];
        emit PositionBurned(tokenId, owner);
    }

    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }

    function setBaseURI(
        string calldata uri
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _baseTokenURI = uri;
    }


    function supportsInterface(
        bytes4 interfaceId
    ) public view override(ERC721Enumerable, AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
