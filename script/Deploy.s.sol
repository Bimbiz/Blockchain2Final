// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { AMM } from "../src/AMM.sol";
import { YieldVault } from "../src/YieldVault.sol";
import { DeFiGovernor } from "../src/DeFiGovernor.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import { ERC20Votes } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import { Nonces } from "@openzeppelin/contracts/utils/Nonces.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract GovernanceToken is ERC20, ERC20Permit, ERC20Votes, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    uint256 public constant MAX_SUPPLY = 100_000_000e18;

    error MaxSupplyExceeded();
    error ZeroAddress();

    event TokensMinted(address indexed to, uint256 amount);
    event TokensBurned(address indexed from, uint256 amount);

    constructor(address admin, address browserWallet)
        ERC20("DeFi Governance Token", "DGT")
        ERC20Permit("DeFi Governance Token")
    {
        if (admin == address(0) || browserWallet == address(0)) {
            revert ZeroAddress();
        }

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MINTER_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);

        _mint(browserWallet, 10_000_000e18);
    }

    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        if (totalSupply() + amount > MAX_SUPPLY) revert MaxSupplyExceeded();
        _mint(to, amount);
        emit TokensMinted(to, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
        emit TokensBurned(msg.sender, amount);
    }

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }

    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}

contract DeploySystem is Script {
    uint256 public constant TIMELOCK_MIN_DELAY = 2 days;

    function run() external {
        uint256 deployerPrivateKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        address deployerAddress = vm.addr(deployerPrivateKey);
        address myMetaMaskWallet = address(0x05e9C5803d79DCef6D7302C85c823f61C9D5251D);
        address chainlinkFeed = 0xd30e2101a97dccb2695E795461114609658FE000;

        vm.startBroadcast(deployerPrivateKey);
        console.log("=== STARTING FULL ECOSYSTEM DEPLOYMENT ===");

        GovernanceToken govToken = new GovernanceToken(deployerAddress, myMetaMaskWallet);
        console.log("Governance Token deployed at:", address(govToken));

        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](1);
        executors[0] = address(0);

        TimelockController timelock = new TimelockController(TIMELOCK_MIN_DELAY, proposers, executors, deployerAddress);
        console.log("TimelockController deployed at:", address(timelock));

        DeFiGovernor governor = new DeFiGovernor(govToken, timelock);
        console.log("DeFiGovernor deployed at:", address(governor));
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));

        YieldVault vault =
            new YieldVault(IERC20(address(govToken)), address(timelock), chainlinkFeed, 3600, 20_000_000e18);
        console.log("YieldVault (ERC-4626) deployed at:", address(vault));

        AMM amm = new AMM(address(govToken), address(vault), address(timelock));
        console.log("AMM Contract deployed at:", address(amm));

        timelock.revokeRole(timelock.DEFAULT_ADMIN_ROLE(), deployerAddress);
        console.log("Deployer revoked admin rights from Timelock. DAO is now autonomous.");
        console.log("=== ECOSYSTEM DEPLOYMENT COMPLETE ===");

        vm.stopBroadcast();
    }
}
