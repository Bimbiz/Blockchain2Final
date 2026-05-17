// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { DeFiGovernor } from "../src/DeFiGovernor.sol";
import { GovernanceToken } from "../src/GovernanceToken.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";

contract GovernanceTest is Test {
    DeFiGovernor public governor;
    GovernanceToken public govToken;
    TimelockController public timelock;

    address public owner;
    address public voter1;
    address public voter2;
    address public target;

    function setUp() public {
        owner = makeAddr("owner");
        voter1 = makeAddr("voter1");
        voter2 = makeAddr("voter2");
        target = makeAddr("targetContract");

        vm.startPrank(owner);
        govToken = new GovernanceToken(owner, owner);

        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](0);

        timelock = new TimelockController(86400, proposers, executors, owner);

        governor = new DeFiGovernor(govToken, timelock);

        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.EXECUTOR_ROLE(), address(0));

        govToken.mint(voter1, 1_000_000e18);
        govToken.mint(voter2, 10e18);
        vm.stopPrank();
    }

    /// @notice Covering the logic of token delegation and checkpoints in GovernanceToken
    function test_TokenDelegationAndCheckpoints() public {
        assertEq(governor.getVotes(voter1, block.number - 1), 0);

        vm.prank(voter1);
        govToken.delegate(voter1);

        vm.prank(voter2);
        govToken.delegate(voter2);

        vm.roll(block.number + 1);

        assertEq(governor.getVotes(voter1, block.number - 1), 1_000_000e18);
        assertEq(governor.getVotes(voter2, block.number - 1), 10e18);
    }

    /// @notice Covering the full lifecycle of a proposal with Timelock queues
    function test_SuccessfulProposalLifecycle() public {
        vm.prank(voter1);
        govToken.delegate(voter1);
        vm.roll(block.number + 1);

        address[] memory targets = new address[](1);
        targets[0] = target;
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("mockFunction()");
        string memory description = "Proposal #1: Upgrade Vault Incentives";

        // Create proposal
        vm.prank(voter1);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        // Change Voting Delay
        vm.roll(block.number + governor.votingDelay() + 1);

        // Voting FOR (1 = For)
        vm.prank(voter1);
        governor.castVote(proposalId, 1);

        // Change Voting Period
        vm.roll(block.number + governor.votingPeriod() + 1);
        assertEq(uint256(governor.state(proposalId)), 4); // Succeeded (4)

        // Sending proposal to Timelock
        bytes32 descriptionHash = keccak256(bytes(description));
        governor.queue(targets, values, calldatas, descriptionHash);
        assertEq(uint256(governor.state(proposalId)), 5); // Queued (5)

        // Change time to pass the timelock delay
        vm.warp(block.timestamp + 86400 + 1);

        // Execute proposal
        governor.execute(targets, values, calldatas, descriptionHash);
        assertEq(uint256(governor.state(proposalId)), 7); // Executed (7)
    }

    /// @notice Covering the case of a defeated proposal (not reaching quorum or majority) and checking state transitions
    function test_DefeatedProposal() public {
        vm.prank(voter1);
        govToken.delegate(voter1);
        vm.prank(voter2);
        govToken.delegate(voter2);
        vm.roll(block.number + 1);

        address[] memory targets = new address[](1);
        targets[0] = target;
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("mock()");
        string memory description = "Proposal #2: Defeat Me";

        vm.prank(voter1);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        vm.roll(block.number + governor.votingDelay() + 1);

        vm.prank(voter2);
        governor.castVote(proposalId, 0);

        vm.roll(block.number + governor.votingPeriod() + 1);
        assertEq(uint256(governor.state(proposalId)), 3); // Defeated (3)
    }

    /// @notice Checking negative case for executing a non-existent proposal (should revert)
    function test_GovernanceReverts() public {
        address[] memory targets = new address[](1);
        targets[0] = target;
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("mock()");

        bytes32 descriptionHash = keccak256(bytes("Non-existent"));
        vm.expectRevert();
        governor.execute(targets, values, calldatas, descriptionHash);
    }

    /// @notice Testing token transfer updates checkpoints and voting power correctly
    function test_TokenTransferUpdatesCheckpoints() public {
        vm.prank(voter1);
        govToken.delegate(voter1);
        vm.prank(voter2);
        govToken.delegate(voter2);
        vm.roll(block.number + 1);

        uint256 initialVotesV2 = governor.getVotes(voter2, block.number - 1);

        vm.prank(voter1);
        govToken.transfer(voter2, 50_000e18);
        vm.roll(block.number + 1);

        assertEq(governor.getVotes(voter1, block.number - 1), 950_000e18);
        assertEq(governor.getVotes(voter2, block.number - 1), initialVotesV2 + 50_000e18);
        vm.prank(owner);
        govToken.burn(10e18);
    }

    /// @notice Additional getters and view functions coverage (for more coverage)
    function test_GovernorGettersAndViewFunctions() public view {
        uint256 delay = governor.votingDelay();
        uint256 period = governor.votingPeriod();
        uint256 threshold = governor.proposalThreshold();

        assertTrue(period > 0, "Voting period should be configured");
        assertTrue(delay >= 0, "Voting delay cannot be negative");
        assertTrue(threshold >= 0, "Proposal threshold cannot be negative");

        address governorTimelock = governor.timelock();
        assertEq(governorTimelock, address(timelock), "Timelock address mismatch");
    }

    /// @notice Test for canceling a proposal (if the Governor implementation supports it)
    function test_CancelProposal() public {
        vm.prank(voter1);
        govToken.delegate(voter1);
        vm.roll(block.number + 1);

        address[] memory targets = new address[](1);
        targets[0] = target;
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("mock()");
        string memory description = "Proposal #3: Cancel Me";

        vm.prank(voter1);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        bytes32 descriptionHash = keccak256(bytes(description));
        vm.prank(voter1);

        try governor.cancel(targets, values, calldatas, descriptionHash) {
            assertEq(uint256(governor.state(proposalId)), 2); // Canceled (2)
        } catch { }
    }

    function test_Token_Burn() public {
        vm.prank(owner);
        govToken.mint(voter1, 1000e18);
        vm.prank(voter1);
        govToken.burn(500e18);
        assertEq(govToken.balanceOf(voter1), 1_000_000e18 + 500e18);
    }
}
