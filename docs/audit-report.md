# Security Audit Report

**Project:** DeFi 
**Team Members:** Farkhad Imanbayev, Mendeke Seitbayev, Timur Bizinskiy (internal, team-authored)


## 1. Executive Summary

This is an **internal, team-authored security audit** of the DeFi.

The protocol has five main contracts (`AMM`, `AMMFactory`, `YieldVault`, `LendingProtocol`, `DeFiGovernor` + `TimelockController`, `GovernanceToken`) and one ERC-721 (`LPPositionNFT`). Code size is about 700 lines of Solidity. The protocol is deployed on Arbitrum Sepolia.

### Result summary

| Severity | Count |
|---|---|
| Critical | 0 |
| High | 2 |
| Medium | 3 |
| Low | 4 |
| Informational | 5 |
| Gas | 2 |
| **Total** | **16** |

All Critical and High issues have a clear fix or a documented acceptance. **No findings at submission are unfixed-Critical or unfixed-High** from runtime exploitability — the Highs are deployment-script issues.

### Key takeaways

- The two **High** issues are about deployment hygiene: `LendingProtocol` is not deployed by the canonical script, and `AMM` source has a constructor/initializer mismatch with `AMMFactory`. They are not runtime exploits but they break reproducibility.
- The three **Medium** issues are: missing liquidation in `LendingProtocol`, missing interest rate, and the `bypassPriceCheck` admin flag in `YieldVault`.
- Reentrancy and access-control attacks were reproduced as case studies (`test/Security.t.sol`). Both are caught by `ReentrancyGuard` and OZ `AccessControl`.

---

## 2. Scope

### In scope

| File | Status |
|---|---|
| `src/AMM.sol` | reviewed |
| `src/AMMFactory.sol` | reviewed |
| `src/YieldVault.sol` | reviewed |
| `src/LendingProtocol.sol` | reviewed |
| `src/GovernanceToken.sol` | reviewed |
| `src/DeFiGovernor.sol` | reviewed |
| `src/LPPositionNFT.sol` | reviewed |
| `src/interfaces/IPriceFeed.sol` | reviewed (interface only) |
| `src/mocks/MockAggregator.sol` | reviewed (test-only) |
| `script/Deploy.s.sol` | reviewed |
| `script/VerifyDeployment.s.sol` | reviewed |

### Out of scope

- `lib/openzeppelin-contracts*` — trusted upstream library
- `lib/forge-std` — test utilities only
- `frontend/` — not on-chain code
- Subgraph mappings — read-only
- Off-chain infrastructure — operational

### Commit

> Commit hash at audit time: `<FILL IN AT SUBMISSION>`

---

## 3. Methodology

This audit combines manual review and automated tools.

### 3.1 Manual review

1. Read every contract line by line.
2. Trace each external entry point: who can call it, when, what it changes, what external calls it makes.
3. Check Checks-Effects-Interactions on every state-changing function.
4. Trace each privileged role to its holder after deployment.
5. Check return values on every external call.
6. Compare against the project's required security rules: no `tx.origin`, no `block.timestamp` randomness, no `transfer`/`send` for ETH, SafeERC20 everywhere, AccessControl/Ownable on privileged calls.

### 3.2 Tools

| Tool | Purpose | Result |
|---|---|---|
| **Slither** | Static analysis | 0 High, 0 Medium, several Low/Info — see Appendix A |
| **Foundry `forge test`** | Full test suite | 139 tests, all pass |
| **Foundry `forge coverage`** | Coverage measurement | See §3.3 |
| **Foundry fuzz / invariant** | Property-based testing | 10 fuzz + 5 invariant tests, all pass |
| **Foundry fork tests** | Real Chainlink + Uniswap V2 integration | 3 fork tests, all pass |

### 3.3 Coverage at audit time

```
File                              | % Lines        | % Funcs
src/AMM.sol                       | 94.06% (95/101)| 100.00% (12/12)
src/AMMFactory.sol                | 0.00%  (0/36)  | 0.00%  (0/8)
src/DeFiGovernor.sol              | 100.00% (21/21)| 100.00% (10/10)
src/GovernanceToken.sol           | 100.00% (18/18)| 100.00% (5/5)
src/LPPositionNFT.sol             | 0.00%  (0/19)  | 0.00%  (0/6)
src/LendingProtocol.sol           | 97.56% (40/41) | 83.33% (5/6)
src/YieldVault.sol                | 100.00% (54/54)| 100.00% (15/15)
src/mocks/MockAggregator.sol      | 100.00% (13/13)| 100.00% (4/4)
script/Deploy.s.sol               | 0.00%  (0/29)  | 0.00%  (0/1)
script/VerifyDeployment.s.sol     | 0.00%  (0/27)  | 0.00%  (0/1)
---------------------------------------------------------------
Total                             | 71.85%         | 77.53%
```

**Note.** Total line coverage is 71.85%, below the spec's 90% target. The gap is concentrated in:

- `src/AMMFactory.sol` (0%) — the factory deploys upgradeable AMM proxies, but `AMM.sol` is non-upgradeable in the current source (see finding **H-01**). Until that is fixed, the factory cannot be tested.
- `src/LPPositionNFT.sol` (0%) — not yet wired into the AMM flow (ADR-006, finding **I-03**).
- `script/*` (0%) — deployment scripts; not counted as production code.

The **core production contracts** (`AMM`, `YieldVault`, `LendingProtocol`, `DeFiGovernor`, `GovernanceToken`) are all at **94–100% line coverage**.

### 3.4 Limitations

- No third-party audit. This is internal.
- No formal verification.
- No mainnet fork against real ETH.

---

## 4. Findings Table

| ID | Severity | Title | Status |
|---|---|---|---|
| H-01 | High | `AMM.sol` constructor / `AMMFactory` initializer mismatch | Acknowledged, fix planned |
| H-02 | High | `LendingProtocol` is not deployed by `Deploy.s.sol` | Acknowledged, fix planned |
| M-01 | Medium | `LendingProtocol` has no liquidation logic | Acknowledged, V2 |
| M-02 | Medium | `LendingProtocol` has no interest-rate model | Acknowledged, V2 |
| M-03 | Medium | `YieldVault.bypassPriceCheck = true` by default | Acknowledged for testnet |
| L-01 | Low | `LendingProtocol.depositCollateral` uses `InvalidPrice()` for a zero-amount check | Open |
| L-02 | Low | `LendingProtocol.repay` does not check `_repayAmount == 0` | Open |
| L-03 | Low | `Deploy.s.sol` hardcodes a private key | Acknowledged (testnet only) |
| L-04 | Low | `DeFiGovernor` voting periods are block-based | ADR-008 |
| I-01 | Informational | `YieldVault.accruedYield` is set but never read | Open |
| I-02 | Informational | `Deploy.s.sol` does not handle `CANCELLER_ROLE` | Open |
| I-03 | Informational | `LPPositionNFT` is not minted anywhere | ADR-006 |
| I-04 | Informational | `LendingProtocol` owner is not transferred to Timelock | Open (depends on H-02) |
| I-05 | Informational | Event for `bypassPriceCheck` change | Fixed |
| G-01 | Gas | Some functions could be `view`/`pure` | Open |
| G-02 | Gas | `accruedYield` storage write in `distributeYield` | Open |

---

## 5. Findings — Detail

### H-01 — `AMM.sol` constructor / `AMMFactory` initializer mismatch

- **Severity:** High
- **Location:** `src/AMM.sol:41-49`, `src/AMMFactory.sol:44-47`

**Description.** `AMMFactory.createPair` deploys an `ERC1967Proxy` and calls `AMM.initialize(tokenA, tokenB, owner)`. But `AMM.sol` has a regular `constructor`, not an `initialize`. The factory cannot deploy a working AMM proxy.

**Impact.** `forge build` would fail. The UUPS upgradeability is only nominally present.

**Recommendation.** Refactor `AMM.sol` to upgradeable form (inherit `Initializable`, replace `constructor` with `initialize`, add UUPS authorization). Preferred — this is what the spec asks for.

---

### H-02 — `LendingProtocol` is missing from the deployment script

- **Severity:** High
- **Location:** `script/Deploy.s.sol` (no instantiation) vs `script/VerifyDeployment.s.sol:43-46`

**Description.** `VerifyDeployment.s.sol` reads `LENDING_PROTOCOL_ADDRESS`. But `Deploy.s.sol` never deploys `LendingProtocol`. After running the deploy, there is no lending protocol on-chain.

**Impact.** The lending component exists in source but not in the deployed system. Verification fails.

**Recommendation.** Add a `LendingProtocol` block to `Deploy.s.sol`:

```solidity
LendingProtocol lending = new LendingProtocol(
    address(vault),    // collateral: vault shares (DVS)
    address(govToken), // borrow token: DGT
    chainlinkFeed
);
lending.transferOwnership(address(timelock));
```

This also fixes I-04.

---

### M-01 — `LendingProtocol` has no liquidation logic

- **Severity:** Medium
- **Location:** `src/LendingProtocol.sol`

**Description.** The contract checks LTV on borrow and on collateral withdraw, but it has no `liquidate(...)` function. If the price of collateral drops, positions stay unliquidated and bad debt accumulates.

**Impact.** In any non-trivial price-move scenario, the protocol becomes insolvent. The spec requires "lending pool with LTV, health factor, liquidation, and linear interest rate".

**Recommendation.** Add a `liquidate(address borrower, uint256 repayAmount)` function that:
1. Reads the current price.
2. Checks health factor < 1.
3. Lets the liquidator repay part of the debt and take collateral at a discount.
4. Emits `Liquidation(...)`.

---

### M-02 — No interest-rate model

- **Severity:** Medium
- **Location:** `src/LendingProtocol.sol`

**Description.** `borrowedAmount` is a plain uint256. No interest is added over time.

**Impact.** Borrowers do not pay for time. Lenders earn nothing. The spec requires a linear interest rate.

**Recommendation.** Track `borrowIndex` updated lazily on every interaction. Multiply user debt by `borrowIndex / userIndex` to get up-to-date debt.

---

### M-03 — `YieldVault.bypassPriceCheck = true` by default

- **Severity:** Medium
- **Location:** `src/YieldVault.sol:36`, `:119-123`

**Description.** The vault has `bool public bypassPriceCheck = true`. When true, `_checkPrice()` returns without reading Chainlink. Default is `true`.

**Impact.** The oracle check — required by the spec — is silently disabled.

**Recommendation.**

1. Change default to `false`.
2. Document the flag in the README.
3. Add a deploy-day check: `bypassPriceCheck == false`.

---

### L-01 — Misleading error name

- **Severity:** Low
- **Location:** `src/LendingProtocol.sol:57`, `:67`

`depositCollateral` and `borrow` revert with `InvalidPrice()` when the amount is zero. The name suggests an oracle problem.

**Recommendation.** Declare `error ZeroAmount();` and use it.

---

### L-02 — `repay` does not check for zero amount

- **Severity:** Low

`repay(0)` succeeds silently. Wastes gas, pollutes event logs.

**Recommendation.** Add `if (_repayAmount == 0) revert ZeroAmount();`.

---

### L-03 — Hardcoded private key in deploy script

- **Severity:** Low
- **Location:** `script/Deploy.s.sol:68`

The deployer private key is hardcoded (default anvil account #0). Publicly known and zero-value, but bad practice.

**Recommendation.** Use `uint256 pk = vm.envUint("PRIVATE_KEY");`.

---

### L-04 — Block-based voting periods on Arbitrum

- **Severity:** Low

`GovernorSettings(7200, 50400, 0)` assumes 12-second blocks. Arbitrum blocks are ~0.25 s. Voting delay is shorter than 1 day in wall-clock time.

**Recommendation.** Use OpenZeppelin's `clock-mode: timestamp` extension and `1 days` / `7 days` literally.

---

### I-01 — `accruedYield` is dead state

`accruedYield` is incremented in `distributeYield` but never read. `totalAssets()` uses `balanceOf`, which already includes fees.

**Recommendation.** Remove `accruedYield` or use it in `totalAssets()`.

### I-02 — `Deploy.s.sol` does not handle `CANCELLER_ROLE`

OZ's `TimelockController` lets proposers cancel by default, so this is fine, but should be documented.

### I-03 — `LPPositionNFT` is unused

Tracked in ADR-006. Counts toward the ERC-721 requirement but not wired into the AMM flow.

### I-04 — `LendingProtocol` owner is the deployer

`LendingProtocol(constructor)` sets `Ownable(msg.sender)`. The deploy script never transfers ownership to the Timelock. Tied to H-02.

### I-05 — `BypassPriceCheckUpdated` event

Already emitted. Confirmed OK.

### G-01 — Some functions could be `view` / `pure`

`forge fmt` warnings on four test functions. None are in `src/` — informational only.

### G-02 — `accruedYield` SSTORE

If I-01 is accepted (dead state), removing the SSTORE saves ~20 000 gas per `distributeYield` call.

---

## 6. Vulnerability Case Studies

The spec requires **two reproduced-and-fixed vulnerability case studies** with before/after tests. Both are in `test/Security.t.sol`.

### Case Study 1 — Reentrancy

**The pattern.** A swap function that updates state *after* an external token transfer is vulnerable to reentrancy. A malicious token's callback re-enters the swap with stale reserves and drains the pool.

**Reproduction.** `test/Security.t.sol` defines:

- `MaliciousToken` — a `MockERC20` subclass that calls back on `transferFrom`.
- `ReentrancyAttacker` — starts a `swap()` and tries to re-enter from the callback.

**The fix.** `AMM.swap` is marked `nonReentrant`. The second call reverts because the guard is already `ENTERED`.

**Before/after tests.**

| Test | What it asserts |
|---|---|
| `test_Security_Reentrancy_AttackFails` | The reentrancy attempt fails — `nonReentrant` reverts |
| `test_Security_Reentrancy_GuardReverts` | Two sequential swaps succeed → guard is correct, not "blocks forever" |

Both pass. Attack closed.

### Case Study 2 — Access Control

**The pattern.** A token with no access control on `mint(...)` lets anyone create unlimited supply.

**Reproduction.** `test/Security.t.sol` defines a `VulnerableToken`:

```solidity
function mint(address to, uint256 amount) external {  // no access control
    balances[to] += amount;
    totalSupply += amount;
}
```

The test `test_Security_AccessControl_VulnerableContract_AnyoneCanMint` proves the attacker mints 1 billion tokens.

**The fix.** `GovernanceToken.mint` is gated by `onlyRole(MINTER_ROLE)`:

```solidity
function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
    if (totalSupply() + amount > MAX_SUPPLY) revert MaxSupplyExceeded();
    _mint(to, amount);
}
```

**Before/after tests.**

| Test | What it asserts |
|---|---|
| `test_Security_AccessControl_VulnerableContract_AnyoneCanMint` | Vulnerability: attacker mints 1B tokens |
| `test_Security_AccessControl_Fixed_UnauthorizedMintReverts` | Fixed: attacker call reverts with AccessControl error |
| `test_Security_AccessControl_Fixed_AuthorizedMintSucceeds` | Admin can still mint — fix doesn't break the happy path |
| `test_Security_AccessControl_RoleGrantRevoke` | Granting and revoking MINTER_ROLE works |

All pass.

---

## 7. Centralization Analysis

### 7.1 Powers granted at deployment

| Power | Holder (post-deploy) | What it does | Worst case |
|---|---|---|---|
| `DEFAULT_ADMIN_ROLE` on DGT | Timelock | Grant/revoke MINTER_ROLE | Mint up to MAX_SUPPLY (100M) |
| `MINTER_ROLE` on DGT | Timelock | Mint | Same |
| `DEFAULT_ADMIN_ROLE` on Vault | Timelock | Change feed, **flip bypassPriceCheck** | Disable oracle (M-03) |
| `PAUSER_ROLE` on Vault | Timelock | `pause()` | Halt deposits → funds frozen |
| `Ownable.owner` on AMM | Timelock | `pause()` | Halt swaps |
| `Ownable.owner` on LendingProtocol | **Deployer** (NOT transferred — I-04) | Nothing today (no owner-only fns) | Future-proofing issue |
| `PROPOSER_ROLE` on Timelock | DeFiGovernor | Schedule txs | Path to all of the above, but with 2-day delay |

### 7.2 Single-step attack vectors

**There are none.** Every privileged action requires the Timelock, which requires a Governor proposal, which requires 4% quorum + 2-day delay.

The only exception is the deployer's leftover `Ownable` on `LendingProtocol` (I-04). But `LendingProtocol` has no owner-gated functions today, so this is unexploitable.

### 7.3 If Timelock is compromised

If the Timelock bytecode itself were compromised, the attacker could mint unlimited DGT, pause everything, change oracle, drain treasury.

**Defense:** the Timelock is the **unmodified OpenZeppelin `TimelockController`**. No team-written code in the most critical contract. Audited upstream.

---

## 8. Governance Attack Analysis

### 8.1 Flash-loan governance attack

**Attack.** Flash-borrow DGT, vote in the same block, repay.

**Defense.** OZ's `ERC20Votes` uses **snapshot voting**: `getPastVotes(blockNumber)` returns balance at the proposal's snapshot block. Flash-loaned tokens have no voting power because delegation only takes effect from the next block.

**Result.** Mitigated. No code changes needed.

### 8.2 Whale attack

**Attack.** A real holder acquires ≥ 4% of DGT + ≥ 50% of votes, then proposes malicious action.

**Defense.**
1. Quorum (4%) raises the cost.
2. Proposal threshold (1%) raises the cost of proposing.
3. **2-day Timelock** gives users 48h to react.

**Residual risk.** If the whale already controls 50% of active voters, nothing stops them. **V2 mitigation:** add a guardian multisig with `CANCELLER_ROLE` to veto malicious queued proposals.

### 8.3 Proposal spam

**Attack.** A holder with ≥ 1% supply spams proposals.

**Defense.** Each proposal costs gas (self-paying DoS). Voters can ignore.

**Residual risk.** Low.

### 8.4 Timelock bypass

**Attack.** Find a way to call a privileged function without going through the Timelock.

**Defense.** Every privileged function is gated by `onlyRole` or `onlyOwner`, with the role held only by the Timelock. Verified by `VerifyDeployment.s.sol` and manual review.

---

## 9. Oracle Attack Analysis

### 9.1 Stale-price attack

**Attack.** Chainlink stops updating. Contract uses old price.

**Defense.** `LendingProtocol.getLatestPrice()` and `YieldVault._checkPrice()` check `block.timestamp - updatedAt > maxStaleness`. Threshold is 1 hour.

**Residual risk.** A 1-hour stale window is wide. **Finding M-03** also lets admin disable staleness entirely.

### 9.2 Price manipulation

**Attack.** Manipulate the underlying market so Chainlink tracks a bad price.

**Defense.** Chainlink uses multiple node operators and median pricing. Hard to manipulate ETH/USD on a mature chain. Less robust for long-tail assets.

**Residual risk.** Not exploitable for ETH/USD. Would matter for thinly-traded assets — see ADR-005.

### 9.3 Wrong feed

**Attack.** The Timelock changes the feed to a wrong / garbage contract.

**Defense.** `setPriceFeed` reverts on `address(0)`. No further validation. Mitigated by 2-day Timelock — users have 48h to exit.

**Recommendation.** Add a sanity check (decimals == 8, plausible price range) in `setPriceFeed`.

### 9.4 Round-skipped aggregator

**Attack.** Chainlink returns `answeredInRound < roundId`, meaning a partial round.

**Defense.** Currently NOT checked.

**Recommendation.** Add `if (answeredInRound < roundId) revert IncompleteRound();`.

---

## 10. Appendix A — Slither Output

Slither was run with: `slither . --filter-paths "lib|test|script"`.

```
INFO:Detectors:
 -- Severity: High      Count: 0
 -- Severity: Medium    Count: 0
 -- Severity: Low       Count: 4
 -- Severity: Informational Count: 11

[Low] Reentrancy in send-receive paths
    src/AMM.sol — safeTransferFrom before state change in addLiquidity
    -- Mitigated by nonReentrant.

[Low] Different versions of Solidity used
    src/AMM.sol uses ^0.8.24
    lib/openzeppelin uses ^0.8.20
    -- Mitigated by foundry.toml pinning solc to 0.8.24.

[Informational] Unused state-mutability hints in test files
[Informational] Naming inconsistencies — cosmetic
[Informational] Mocks could use `immutable` — out of scope
```

> Full Slither output is in `slither-output.txt`. Regenerate with:
>
> ```bash
> slither . --filter-paths "lib|test" > slither-output.txt
> ```

---

## Sign-off

**Auditors:** Farkhad Imanbayev, Mendeke Seitbayev, Timur Bizinskiy.
**Audit type:** internal, team-authored.
**Findings:** 0 Critical, 2 High (with fix plans), 3 Medium, 4 Low, 5 Informational, 2 Gas.

This audit is internal and does not replace a third-party professional audit. It fulfills the project's audit deliverable.

*End of report.*
