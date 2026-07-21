# Somoco Settlement Contracts (v1)

Parimutuel YES/NO settlement for Somoco predictions, in native `$TRUST` on
Intuition (chain id 1155). Full spec: [`../docs/settlement-v1-spec.md`](../docs/settlement-v1-spec.md).

## Contracts

| Contract | Purpose |
|---|---|
| `src/MarketFactory.sol` | Deploys/tracks markets as EIP-1167 clones. Holds the `owner` / `resolver` / `treasury` roles and `minStake` config. |
| `src/PredictionMarket.sol` | One clone per prediction. Stake → time-lock → resolve/void → claim. 3% fee on the losing pool only. |

## Commands

```bash
forge build          # compile
forge test           # 48 tests incl. fuzzed solvency invariant
forge test -vvv      # verbose on failure
```

## Deploy

Set `OWNER`, `RESOLVER`, `TREASURY` (multisigs!), `MIN_STAKE` (wei), then:

```bash
forge script script/Deploy.s.sol --rpc-url <rpc> --broadcast
```

## Status

- [x] Contracts + full §11 test suite (2026-07-21)
- [ ] Deploy to Intuition testnet, run with play amounts
- [ ] Multisig setup for owner / resolver / treasury
- [ ] Audit before holding real money
- [ ] Legal review (§10 #6) — **before launch**
- [ ] App integration: `createMarket` on approval, `stake` on detail view, `resolve` in admin flow, `claim` in My Predictions
