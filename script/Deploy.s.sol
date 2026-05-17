// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {AMM} from "../src/AMM.sol";
import {YieldVault} from "../src/YieldVault.sol";
import {DeFiGovernor} from "../src/DeFiGovernor.sol";
import {LendingProtocol} from "../src/LendingProtocol.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";

// Токен управления с поддержкой функционала снимков весов голосования (Votes)
contract GovernanceToken is ERC20, ERC20Permit, ERC20Votes {
    constructor() ERC20("Governance Token", "GOV") ERC20Permit("Governance Token") {
        _mint(msg.sender, 1000000 ether);
    }

    // Необходимые переопределения (overrides) для Solidity из-за множественного наследования
    function _update(address from, address to, uint256 value)
        internal
        override(ERC20, ERC20Votes)
    {
        super._update(from, to, value);
    }

    function nonces(address owner)
        public
        view
        override(ERC20Permit, Nonces)
        returns (uint256)
    {
        return super.nonces(owner);
    }
}

contract DeploySystem is Script {
    uint256 public constant TIMELOCK_MIN_DELAY = 2 days;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployerAddress = vm.addr(deployerPrivateKey);
        
        address chainlinkFeed = vm.envAddress("CHAINLINK_FEED"); 

        vm.startBroadcast(deployerPrivateKey);
        console.log("=== STARTING FULL ECOSYSTEM DEPLOYMENT ===");

        // 1. Деплоим токен управления (теперь он совместим с IVotes)
        GovernanceToken govToken = new GovernanceToken();
        console.log("Governance Token deployed at:", address(govToken));

        // 2. Деплоим TimelockController
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

        // 3. Деплоим DeFiGovernor (DAO)
        DeFiGovernor governor = new DeFiGovernor(govToken, timelock);
        console.log("DeFiGovernor deployed at:", address(governor));

        // Настраиваем роли
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));

        // 4. Деплоим YieldVault (ERC-4626)
        YieldVault vault = new YieldVault(
            govToken,
            address(timelock),
            chainlinkFeed,
            3600,
            100 * 10**8
        );
        console.log("YieldVault (ERC-4626) deployed at:", address(vault));

        // 5. Деплоим Имплементацию AMM и инициализируем её
        AMM amm = new AMM();
        amm.initialize(address(govToken), address(vault), address(timelock));
        console.log("AMM Implemented and Initialized at:", address(amm));

        // 6. ДЕПЛОЙ LENDING PROTOCOL
        LendingProtocol lending = new LendingProtocol(
            address(vault),
            address(govToken),
            chainlinkFeed
        );
        console.log("LendingProtocol deployed at:", address(lending));

        // Передаем владение Кредитным протоколом на Timelock (DAO)
        lending.transferOwnership(address(timelock));
        console.log("LendingProtocol ownership transferred to Timelock");

        // Отказываемся от прав админа в пользу децентрализации
        timelock.revokeRole(timelock.DEFAULT_ADMIN_ROLE(), deployerAddress);
        console.log("Deployer revoked admin rights from Timelock. DAO is now fully autonomous.");

        console.log("=== ECOSYSTEM DEPLOYMENT COMPLETE ===");
        vm.stopBroadcast();
    }
}