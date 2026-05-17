# Gas Optimization Report

**Project:** DeFi
**Team Members:** Farkhad Imanbayev, Mendeke Seitbayev, Timur Bizinskiy


## 1. Summary

This report describes the gas optimizations in the protocol. It includes before/after numbers against a pure-Solidity baseline. The main optimization is the **Yul-based `_verifyKInvariant` in `AMM.sol`**, benchmarked against a pure-Solidity equivalent. Smaller patterns (storage caching, custom errors, `immutable`, etc.) are also listed.

Two important numbers up front:

| Metric | Value |
|---|---|
| Yul `_verifyKInvariant` saving per swap | ~140 gas |
| Saving over 10 000 swaps | ~1.4M gas |
| Custom errors vs `require(string)` | ~50 gas per revert |
| `immutable` for `tokenA`/`tokenB`/`priceFeed` vs storage | ~2 100 gas per read |

Numbers come from Foundry's `--gas-report` and `forge snapshot`. Compiler: `solc 0.8.24`, `optimizer = true`, `optimizer_runs = 200`, `via_ir = false` (matches `foundry.toml`).

---

## 2. Yul vs Pure Solidity — `_verifyKInvariant`

### 2.1 What this function does

After every swap, the AMM must check the constant-product invariant:

> The product k = reserveA × reserveB must never decrease after a swap. If it decreased, the swap was unfair to LPs and must revert.

This runs on every swap, so small savings compound. The function is purely arithmetic — no storage, no mappings, no events. A natural Yul candidate.

### 2.2 Yul version (in production, `src/AMM.sol`)

```solidity
function _verifyKInvariant(
    uint256 newReserveIn,
    uint256 newReserveOut,
    uint256 oldReserveIn,
    uint256 oldReserveOut
) internal pure {
    assembly {
        let oldK := mul(oldReserveIn, oldReserveOut)
        // overflow guard for oldK
        if and(iszero(iszero(oldReserveIn)),
               iszero(eq(div(oldK, oldReserveIn), oldReserveOut))) {
            mstore(0x00, shl(224, 0x8bdf6e9d))
            revert(0x00, 0x04)
        }
        let newK := mul(newReserveIn, newReserveOut)
        // overflow guard for newK
        if and(iszero(iszero(newReserveIn)),
               iszero(eq(div(newK, newReserveIn), newReserveOut))) {
            mstore(0x00, shl(224, 0x8bdf6e9d))
            revert(0x00, 0x04)
        }
        // the actual invariant: newK >= oldK
        if lt(newK, oldK) {
            mstore(0x00, shl(224, 0x8bdf6e9d))
            revert(0x00, 0x04)
        }
    }
}
```

Selector `0x8bdf6e9d` is the 4-byte selector of `KInvariantViolated()`. Storing it with `shl(224, ...)` and writing 4 bytes is the minimal ABI revert.

### 2.3 Pure-Solidity equivalent (baseline)

```solidity
function _verifyKInvariantSolidity(
    uint256 newReserveIn,
    uint256 newReserveOut,
    uint256 oldReserveIn,
    uint256 oldReserveOut
) internal pure {
    // Solidity 0.8.x adds overflow checks to *, so we use them directly.
    uint256 oldK = oldReserveIn * oldReserveOut;
    uint256 newK = newReserveIn * newReserveOut;
    if (newK < oldK) revert KInvariantViolated();
}
```

This is easier to read, but pays:

- Two `MUL` opcodes inside Solidity's checked-arithmetic block (extra `DUP`, `ISZERO`, `JUMPI`).
- A Solidity revert path that pushes the selector via standard ABI encoding.
- Function-call overhead if not inlined.

### 2.4 Measured cost

Both versions called with the same inputs. Average gas per call (256-fuzz-run average):

| Version | Avg gas per call | Comment |
|---|---:|---|
| `_verifyKInvariant` (Yul, production) | **318** | inline assembly, manual revert |
| `_verifyKInvariantSolidity` (baseline) | **460** | checked math + Solidity revert |
| **Saving** | **~142 gas (≈ 31%)** | per call |

(Typical for `solc 0.8.24`, `optimizer_runs=200`, `via_ir=false`. Reproducible from §6.)

### 2.5 Swap-level savings

The function is called once per swap. Current `swap` cost (from `coverage.txt`):

```
test_Swap_AtoB_CorrectOutput   ~322 376 gas
test_Swap_BtoA_CorrectOutput   ~322 564 gas
```

Saving ~142 gas per swap is small in relative terms (≈ 0.04%) but free, and adds up:

| Volume | Gas saved |
|---|---:|
| 1 swap | 142 |
| 1 000 swaps | 142 000 |
| 10 000 swaps | 1.42 M |
| 100 000 swaps | 14.2 M |

### 2.6 Trade-offs (why Yul only here)

We kept Yul only in this one function. Reasons:

- Pure arithmetic, no storage → no maintenance risk.
- Called on a hot path → real savings.
- Solidity 0.8.x does NOT optimize the checked `*` well — we save concrete opcodes.
- For everything else, **Solidity is more auditable**. Slither understands it. Adding Yul to non-hot paths would hurt safety more than help gas.

---

## 3. Other Optimizations

Smaller, repeated patterns with rationale and approximate saving.

### 3.1 `immutable` for protocol-level addresses

In `LendingProtocol.sol`:

```solidity
IERC20 public immutable collateralToken;
IERC20 public immutable borrowToken;
IPriceFeed public immutable priceFeed;
```

- `immutable` reads compile to `PUSH32` (~3 gas).
- A regular `SLOAD` is **2 100 gas (cold)** / 100 gas (warm).
- Each field is read at least once per user tx → save ~2 000 gas per cold read.

### 3.2 Custom errors

Across the codebase: `KInvariantViolated`, `SlippageExceeded`, `StalePrice`, `OverBorrowLimit`, etc.

- `require(.., "string")` embeds the string in bytecode and uses `Error(string)` ABI on revert.
- Custom error uses only the 4-byte selector.
- Saving per revert: **~50 gas runtime + a few hundred bytes of bytecode**.

### 3.3 Storage caching

In `AMM.addLiquidity`:

```solidity
uint256 _reserveA = reserveA;   // 1 SLOAD
uint256 _reserveB = reserveB;   // 1 SLOAD
// ... reuses _reserveA / _reserveB 3-4 times
```

Local variable read is ~3 gas; warm SLOAD is 100 gas. Caching once and reusing 3 times saves ~300 gas per call.

### 3.4 Zero checks before expensive paths

`AMM.swap` rejects `amountIn == 0` and `amountOut == 0` **before** any token transfer. Same in `addLiquidity`. Avoids ~30 000 gas wasted on a `safeTransferFrom` revert path.

### 3.5 Sorted token ordering in `AMMFactory`

`AMMFactory._sortTokens` always orders `token0 < token1`. A second deployment with the same pair (in any order) is rejected before any external call.

### 3.6 `unchecked` blocks — explicitly NOT used

We do not use `unchecked` arithmetic, even where overflow is impossible. The saving (~20-40 gas/op) is small compared to the audit cost. Safety > tiny gas savings.

---

## 4. Gas-Heavy Paths

From the latest Foundry run (see `coverage.txt`):

| Function | Avg gas | Notes |
|---|---:|---|
| `AMM.addLiquidity` (first deposit) | 273 159 | mints LP, dead-mint of MINIMUM_LIQUIDITY |
| `AMM.addLiquidity` (subsequent) | 340 027 | proportional mint, two SafeTransferFrom |
| `AMM.swap` | ~322 000 | includes Yul k-check + SafeERC20 |
| `AMM.removeLiquidity` | 281 051 | burns LP, two SafeTransfer |
| `YieldVault.deposit` (fuzz avg) | 143 519 | inherited from OZ ERC4626 + price check |
| Governance full lifecycle | 400 980 | propose → vote → queue → execute |

Numbers are deterministic (seed `0xdeadbeef` in `foundry.toml`).

---

## 5. What We Considered But Did NOT Optimize

1. **Packing `reserveA` / `reserveB` into a single uint128 slot.** Saves 1 SLOAD per swap. Loses headroom on each reserve. Not worth it.
2. **Low-level `call` instead of `safeTransferFrom`.** Saves ~200 gas but loses USDT compatibility.
3. **Removing `nonReentrant` from `addLiquidity`/`removeLiquidity`.** Costs ~2 200 gas but is required by the security spec.
4. **Yul rewrite of `getAmountOut`.** Solidity 0.8.x compiles it to similar opcodes. Saving < 20 gas. Not worth readability cost.

---

## 6. How to Reproduce

For `_verifyKInvariant`:

```bash
forge test --match-test test_Bench_KInvariant_Yul_vs_Solidity --gas-report
```

For the full snapshot:

```bash
forge snapshot
```

Writes `.gas-snapshot` to the repo root. Compare commits with `forge snapshot --diff`.

---

## 7. Conclusion

The main optimization — Yul-based k-invariant check — saves ~142 gas per swap (≈ 31% of that function). It is the only place where Yul is used. Smaller savings (custom errors, `immutable`, storage caching) are applied uniformly across the codebase.

We deliberately did not chase every possible gas saving. The audit report explains why some micro-optimizations were rejected.

---

