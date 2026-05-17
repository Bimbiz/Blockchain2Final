# DeFi - Blockchain Technologies 2 Final Project

A production-grade DeFi protocol that combines an AMM, an ERC-4626 yield vault, a lending market and a full DAO governance stack. Built with Foundry, deployed on Arbitrum Sepolia, indexed by The Graph and served by a Wagmi/Viem frontend.

Group: SE - 2438
Team Members: Farkhad Imanbayev, Timur Bizinskiy, Mendeke Seitbayev


## 1. Project Overview

This project is a **DeFi** that contains five connected pieces:

| Component | Standard / Pattern | What it does |
|---|---|---|
| `AMM` | Constant-product (x·y=k), 0.3% fee, ERC-20 LP tokens | Token-to-token swaps and liquidity provision |
| `YieldVault` | ERC-4626 tokenized vault | Users deposit assets, get vault shares (DVS), yield accrues from protocol fees |
| `LendingProtocol` | Custom collateralized lending | Deposit DVS as collateral, borrow against it with 75% LTV |
| `GovernanceToken` (DGT) | ERC-20 + ERC20Votes + ERC20Permit | Governance token used for DAO voting |
| `DeFiGovernor` + `TimelockController` | OpenZeppelin Governor stack | Full propose → vote → queue → execute lifecycle, 2-day timelock |

The protocol is **owned by the Timelock**, not by an EOA. After deployment the deployer revokes its admin role and the DAO becomes autonomous.

External integrations:
- **Chainlink price feeds** with staleness check (used by `YieldVault` and `LendingProtocol`)
- **The Graph subgraph** for indexing protocol events
- **L2 deployment** on Arbitrum Sepolia (chainId 421614)

---


## 2. Architecture at a Glance

```
                        ┌──────────────────────┐
                        │  Frontend (Wagmi)    │
                        │  React / HTML + JS   │
                        └──────────┬───────────┘
                                   │
                  ┌────────────────┼────────────────┐
                  │                │                │
                  ▼                ▼                ▼
          ┌─────────────┐  ┌─────────────┐  ┌─────────────┐
          │   AMM       │  │ YieldVault  │  │  Governor   │
          │  (x·y=k)    │  │  (ERC-4626) │  │  + Timelock │
          └──────┬──────┘  └──────┬──────┘  └──────┬──────┘
                 │                │                │
                 │     ┌──────────┴────────┐       │
                 ▼     ▼                   ▼       ▼
          ┌─────────────┐           ┌─────────────────┐
          │  Chainlink  │           │ GovernanceToken │
          │  Price Feed │           │ (ERC20Votes)    │
          └─────────────┘           └─────────────────┘
                 ▲
                 │
          ┌─────────────┐
          │ The Graph   │  ← indexes all events
          │  Subgraph   │
          └─────────────┘
```

For full diagrams (C4 context, container, sequence) see [`docs/architecture.md`](docs/architecture.md).

---

## 3. Deployed Contracts (Arbitrum Sepolia)

All contracts are deployed and verified on **Arbitrum Sepolia (chainId 421614)**.

| Contract | Address |
|---|---|
| GovernanceToken (DGT) | [`0xda8ecc4a0ec8fc45de17d74718e6092e46e46f23`](https://sepolia.arbiscan.io/address/0xda8ecc4a0ec8fc45de17d74718e6092e46e46f23) |
| TimelockController | [`0x386758f9cb9d24946fc33a194535176af7f9547d`](https://sepolia.arbiscan.io/address/0x386758f9cb9d24946fc33a194535176af7f9547d) |
| DeFiGovernor | [`0xd6d5f47be1f2d427857e8d4835774d0e8c5e96be`](https://sepolia.arbiscan.io/address/0xd6d5f47be1f2d427857e8d4835774d0e8c5e96be) |
| YieldVault (DVS) | [`0x24aec982938af51c7fd32d9a9555a11ba2d6de1e`](https://sepolia.arbiscan.io/address/0x24aec982938af51c7fd32d9a9555a11ba2d6de1e) |
| AMM | [`0x2aa5e83311d3c647fb25d003eafcedb57dd4c803`](https://sepolia.arbiscan.io/address/0x2aa5e83311d3c647fb25d003eafcedb57dd4c803) |

**Network parameters used:**
- Chainlink ETH/USD feed (Arbitrum Sepolia): `0xd30e2101a97dccb2695E795461114609658FE000`
- Price staleness threshold: 3600 seconds
- Timelock min delay: 2 days
- Voting delay: 1 day (7200 blocks)
- Voting period: 1 week (50400 blocks)
- Quorum: 4%
- Proposal threshold: 1% of total supply

---

## 4. Repository Layout

```
.
├── src/                       # Solidity sources
│   ├── AMM.sol                # Constant-product AMM with Yul k-check
│   ├── AMMFactory.sol         # Factory: CREATE + CREATE2
│   ├── YieldVault.sol         # ERC-4626 vault with Chainlink price gate
│   ├── LendingProtocol.sol    # Collateralized lending with LTV / liquidation
│   ├── GovernanceToken.sol    # ERC20Votes + ERC20Permit + AccessControl
│   ├── DeFiGovernor.sol       # OpenZeppelin Governor stack
│   ├── LPPositionNFT.sol      # ERC-721 LP position
│   ├── interfaces/
│   │   └── IPriceFeed.sol     # Minimal Chainlink AggregatorV3 interface
│   └── mocks/
│       └── MockAggregator.sol # Controllable price feed for tests
│
├── test/                      # Foundry tests (80+ total)
│   ├── AMM.t.sol              # Unit tests for AMM (45 tests)
│   ├── Vault.t.sol            # ERC-4626 unit + rounding invariants
│   ├── LendingProtocol.t.sol  # Lending unit tests
│   ├── Governance.t.sol       # Governor lifecycle tests (7 tests)
│   ├── Security.t.sol         # Reentrancy + access-control case studies
│   ├── Fuzz.t.sol             # Fuzz tests (10 tests)
│   ├── Invariant.t.sol        # Invariant tests (5 properties)
│   ├── Fork.t.sol             # Fork tests against real Chainlink / Uniswap
│   └── helpers/
│       └── MockERC20.sol      # Test-only ERC-20
│
├── script/
│   ├── Deploy.s.sol           # Full system deployment script
│   └── VerifyDeployment.s.sol # Post-deployment sanity check
│
├── frontend/                  # dApp (HTML + JS + Wagmi/Viem)
│   ├── index.html
│   ├── app.js
│   └── style.css
│
├── docs/
│   ├── architecture.md        # System architecture document
│   ├── audit-report.md        # Internal security audit report
│   └── gas-optimization.md    # Gas optimization report
│
├── broadcast/                 # Foundry deployment logs (used by docs)
├── foundry.toml               # Foundry config (solc 0.8.24, optimizer on)
├── coverage.txt               # Latest coverage report
└── README.md
```

---

## 5. Installation

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (forge, cast, anvil)
- Node.js ≥ 18 (only for the frontend / subgraph tooling)
- Git

### Clone and install

```bash
git clone <repo-url>
cd Blockchain2Final-main

# Install Foundry libraries
forge install

# Build all contracts
forge build
```

### Environment variables

Create a `.env` file in the project root:

```bash
# RPC endpoints
ETH_RPC_URL=https://eth.llamarpc.com
ARBITRUM_SEPOLIA_RPC_URL=https://sepolia-rollup.arbitrum.io/rpc

# Deployment
PRIVATE_KEY=0x...                # Deployer private key (testnet only!)
ETHERSCAN_API_KEY=...            # For contract verification

# Used by VerifyDeployment.s.sol
AMM_ADDRESS=0x2aa5e83311d3c647fb25d003eafcedb57dd4c803
YIELD_VAULT_ADDRESS=0x24aec982938af51c7fd32d9a9555a11ba2d6de1e
GOVERNOR_ADDRESS=0xd6d5f47be1f2d427857e8d4835774d0e8c5e96be
LENDING_PROTOCOL_ADDRESS=0x...   # fill in after deployment
```


---

## 6. How to Run Tests

The full Foundry test suite has **80+ tests** across unit, fuzz, invariant and fork categories.

### Run all tests

```bash
forge test
```

### Run only a subset

```bash
# Only AMM tests
forge test --match-path test/AMM.t.sol

# Only fuzz tests, more runs
forge test --match-path test/Fuzz.t.sol --fuzz-runs 1000

# Only invariant tests
forge test --match-path test/Invariant.t.sol
```

### Verbose output (for debugging)

```bash
forge test -vvv
```

### Fork tests

Fork tests need a mainnet RPC URL:

```bash
forge test --match-path test/Fork.t.sol --fork-url $ETH_RPC_URL
```

### Coverage report

```bash
forge coverage --report lcov
forge coverage --report summary > coverage.txt
```

Latest coverage is committed in [`coverage.txt`](coverage.txt). Line coverage on contracts in `src/` is ≥ 90%.

### Static analysis (Slither)

```bash
pip install slither-analyzer
slither . --filter-paths "lib|test"
```

Slither reports **zero High and zero Medium findings**. Lows and Informationals are documented in [`docs/audit-report.md`](docs/audit-report.md).

---

## 7. How to Run the Frontend

The frontend is a simple HTML + JS app that uses Wagmi/Viem for wallet interaction.

```bash
cd frontend

# Easiest: just open with any static server
python3 -m http.server 8080
# or
npx serve .
```

Open [http://localhost:8080](http://localhost:8080) in a browser with MetaMask installed.

### Features

- Connect with MetaMask
- Switch to Arbitrum Sepolia (prompted automatically if on wrong network)
- Read balances, voting power, delegation, pool reserves, vault shares
- Write transactions: swap, deposit to vault, vote on proposals
- View active proposals with their state (Pending / Active / Succeeded / Defeated / Queued / Executed)
- Read indexed data from The Graph subgraph

All transaction errors (rejection, wrong chain, low balance) show a readable message — no raw RPC errors.

---

## 8. How to Deploy

### Deploy to a fresh testnet

The deployment is **fully scripted and reproducible** — no manual steps.

```bash
forge script script/Deploy.s.sol:DeploySystem \
  --rpc-url $ARBITRUM_SEPOLIA_RPC_URL \
  --broadcast \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY
```

This script does the following in one transaction batch:

1. Deploys `GovernanceToken` and mints 10M DGT to the configured wallet.
2. Deploys `TimelockController` with a 2-day delay.
3. Deploys `DeFiGovernor` and grants it the `PROPOSER_ROLE` on the timelock.
4. Deploys `YieldVault` (ERC-4626) with the Chainlink ETH/USD feed.
5. Deploys `AMM` with DGT and DVS as the trading pair.
6. **Revokes the deployer's admin role on the Timelock** — the DAO is now autonomous.

### Verify deployment correctness

```bash
forge script script/VerifyDeployment.s.sol:VerifyDeployment \
  --rpc-url $ARBITRUM_SEPOLIA_RPC_URL
```

This is a read-only script that checks:
- AMM tokens are wired correctly
- Vault asset and price feed match the spec
- Governor is named correctly and has the right voting delay
- LendingProtocol owner is the Timelock (not an EOA)

The output is plain text and must show the expected addresses; a sample saved output is included in `docs/verify-output.txt`.

---

## 9. Security

The project follows the following security rules (all checked in `Security.t.sol` and Slither):

- Every state-changing function uses **Checks-Effects-Interactions** or `ReentrancyGuard`.
- All privileged functions use **OpenZeppelin AccessControl** or `Ownable`. No unguarded admin function.
- No `tx.origin` for authorization.
- No `block.timestamp` as a source of randomness.
- No `transfer` / `send` for ETH — only `call{value:}` with success check.
- All ERC-20 interactions go through **SafeERC20**.
- Two reproduced-and-fixed vulnerability case studies (reentrancy + access control) live in `test/Security.t.sol`.

Full audit findings, centralization analysis, governance attack analysis and oracle attack analysis are in [`docs/audit-report.md`](docs/audit-report.md).

---

## 10. Documentation Index

| Document | Purpose |
|---|---|
| [`docs/architecture.md`](docs/architecture.md) | System architecture, C4 diagrams, sequence flows, storage layout, ADRs |
| [`docs/audit-report.md`](docs/audit-report.md) | Internal security audit, findings table, attack analyses, Slither output |
| [`docs/gas-optimization.md`](docs/gas-optimization.md) | Gas benchmarks, Yul vs Solidity comparison, optimization rationale |
| [`coverage.txt`](coverage.txt) | Latest Foundry coverage report |



