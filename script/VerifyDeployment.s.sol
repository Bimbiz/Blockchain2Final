// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {AMM} from "../src/AMM.sol";
import {YieldVault} from "../src/YieldVault.sol";
import {DeFiGovernor} from "../src/DeFiGovernor.sol";
import {LendingProtocol} from "../src/LendingProtocol.sol";

contract VerifyDeployment is Script {
    function run() external view {
        console.log("=== STARTING POST-DEPLOYMENT SANITY CHECKS ===");

        address ammAddress = vm.envAddress("AMM_ADDRESS");
        address vaultAddress = vm.envAddress("YIELD_VAULT_ADDRESS");
        address governorAddress = vm.envAddress("GOVERNOR_ADDRESS");
        address lendingAddress = vm.envAddress("LENDING_PROTOCOL_ADDRESS");

        console.log("Checking AMM at:", ammAddress);
        AMM amm = AMM(ammAddress);
        console.log("AMM TokenA:", address(amm.tokenA()));
        console.log("AMM TokenB:", address(amm.tokenB()));

        console.log("-----------------------------------------");

        console.log("Checking YieldVault at:", vaultAddress);
        YieldVault vault = YieldVault(vaultAddress);
        console.log("Vault Asset Token:", vault.asset());
        console.log("Vault Price Feed:", address(vault.priceFeed()));

        console.log("-----------------------------------------");

        console.log("Checking DeFiGovernor at:", governorAddress);
        // Приводим адрес к payable, так как контракт имеет payable fallback логику
        DeFiGovernor governor = DeFiGovernor(payable(governorAddress));
        console.log("Governor Name:", governor.name());
        console.log("Voting Delay (blocks):", governor.votingDelay());

        console.log("-----------------------------------------");

        console.log("Checking LendingProtocol at:", lendingAddress);
        LendingProtocol lending = LendingProtocol(lendingAddress);
        console.log("Lending Collateral Token:", address(lending.collateralToken()));
        console.log("Lending Borrow Token:", address(lending.borrowToken()));
        console.log("Lending Contract Owner (DAO):", lending.owner());

        console.log("=== ALL SANITY CHECKS COMPLETED SUCCESSFULLY ===");
    }
}