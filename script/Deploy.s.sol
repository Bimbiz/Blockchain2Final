// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {AMM} from "../src/AMM.sol";
import {YieldVault} from "../src/YieldVault.sol";
import {DeFiGovernor} from "../src/DeFiGovernor.sol";
import {GovernanceToken} from "../src/GovernanceToken.sol";
import {
    TimelockController
} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {
    ERC1967Proxy
} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DeploySystem is Script {
    uint256 public constant TIMELOCK_MIN_DELAY = 2 days;

    function run() external {
        uint256 deployerPrivateKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        address deployerAddress = vm.addr(deployerPrivateKey);
        address myMetaMaskWallet = address(
            0x05e9C5803d79DCef6D7302C85c823f61C9D5251D
        );
        address chainlinkFeed = 0xd30e2101a97dccb2695E795461114609658FE000;

        vm.startBroadcast(deployerPrivateKey);
        console.log("=== STARTING FULL ECOSYSTEM DEPLOYMENT ===");

        GovernanceToken govToken = new GovernanceToken(
            deployerAddress,
            myMetaMaskWallet
        );
        console.log("Governance Token deployed at:", address(govToken));

        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](1);
        executors[0] = address(0);

        TimelockController timelock = new TimelockController(
            TIMELOCK_MIN_DELAY,
            proposers,
            executors,
            deployerAddress
        );
        console.log("TimelockController deployed at:", address(timelock));

        DeFiGovernor governor = new DeFiGovernor(govToken, timelock);
        console.log("DeFiGovernor deployed at:", address(governor));
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));

        // Deploy YieldVault as UUPS proxy
        YieldVault vaultImpl = new YieldVault();
        console.log(
            "YieldVault implementation deployed at:",
            address(vaultImpl)
        );

        bytes memory vaultInitData = abi.encodeCall(
            YieldVault.initialize,
            (
                IERC20(address(govToken)),
                address(timelock),
                chainlinkFeed,
                3600,
                20_000_000e18
            )
        );
        ERC1967Proxy vaultProxy = new ERC1967Proxy(
            address(vaultImpl),
            vaultInitData
        );
        YieldVault vault = YieldVault(address(vaultProxy));
        console.log("YieldVault (UUPS proxy) deployed at:", address(vault));

        AMM amm = new AMM(address(govToken), address(vault), address(timelock));
        console.log("AMM Contract deployed at:", address(amm));

        timelock.revokeRole(timelock.DEFAULT_ADMIN_ROLE(), deployerAddress);
        console.log(
            "Deployer revoked admin rights from Timelock. DAO is now autonomous."
        );
        console.log("ECOSYSTEM DEPLOYMENT COMPLETE");

        vm.stopBroadcast();
    }
}
