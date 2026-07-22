# Deployments

## Intuition mainnet (chain 1155) — v1.2 TEST deployment, 2026-07-22

> v1.2 adds **early-exit unstake**: `unstake(Side)` lets a user withdraw a full
> position before lock, keeping 60% (`UNSTAKE_PENALTY_BPS = 4000`); the
> forfeited 40% stays in the pool (`forfeitPool`) and boosts the winning side at
> resolution. Void condition changed to "winning side empty" (a one-sided market
> where only winners staked now pays them their stake back instead of voiding).
> 60 tests green incl. fuzzed solvency across stake+unstake. Still single-EOA
> roles: redeploy with multisigs (after audit + legal review) before real money.

| What | Address |
|---|---|
| `MarketFactory` v1.2 | `0xCF1893f255DD8d197f3415411658329d432DaC84` |
| `PredictionMarket` implementation v1.2 | `0xa811De948921A5EC3D8ab607445f65008af66EaC` |
| Owner | deployed by `0x665e...82C5`, ownership transferred to Coco's burner `0x45E4...D64b` (pending acceptance via the Approve page's activate button) |
| Resolver / Treasury | `0x45E4300Ff44a1360494e233eB7E9dcC2F8DaD64b` — Coco's burner |
| Min stake | `0.01 TRUST` · creator fee 50 bps · exit penalty 4000 bps (40%) |

4 markets recreated on v1.2 (creator = burner): Messi Ballon d'Or (note: created
with resolution 2026-10-31, DB says 10-26 — harmless date typo on a test market),
coco GOAT, saturn/100-people, solstice rug. v1.1 `0xB8aA...3364` retired with 0.2
TRUST of test stakes still in it (reclaimable: resolve on the old factory + claim).

---

## v1.1 (retired 2026-07-22)

> v1.1: 3% fee splits — `creatorFeeBps` (0.5% default) to the creator,
> remainder to the treasury — auto-distributed at resolution. `createMarket`
> gained a `creator` param. Superseded by v1.2 (early-exit unstake) above.

| What | Address |
|---|---|
| `MarketFactory` v1.1 | `0xB8aAEF799ddA3d514Dc493eEC0Cf3B7989E13364` |
| `PredictionMarket` impl v1.1 | `0x16AF15104cFEb9a563b5e492195F2544D7A91fa6` |

Holds 0.2 TRUST of test stakes (reclaimable: resolve on this factory + claim).

---

## v1.0 (retired 2026-07-22)

### Original v1.0 deployment, 2026-07-21

> ⚠️ Test deployment: roles are single EOAs, not multisigs. Redeploy with
> multisigs (and after audit + legal review) before real users stake real money.

| What | Address |
|---|---|
| `MarketFactory` | `0x6B8481401648f540fe87B6173d80E37D6B501313` |
| `PredictionMarket` implementation | `0xf0b85e89B622186481b106C7282B9AC9F08497a0` |
| Owner (creates markets) | `0x665e3192367629dde7d72c27728359f7038D82C5` — "intuition" Foundry keystore |
| Resolver | `0x45E4300Ff44a1360494e233eB7E9dcC2F8DaD64b` — Coco's burner (browser wallet) |
| Treasury | `0x45E4300Ff44a1360494e233eB7E9dcC2F8DaD64b` — same burner |
| Min stake | `0.01 TRUST` (1e16 wei) |

RPC: `https://rpc.intuition.systems`

### Markets created (2026-07-21)

| Prediction (termId prefix) | Market | Locks |
|---|---|---|
| coco GOAT (`0x117349…`) | `0x01e3153adc7ae00e2bbd6c353a39b38e04023b73` | 2026-12-30 |
| saturn (`0xd95926…`) | `0x573246b826226d4bba4c568bf9b2a42b0508994c` | 2026-12-30 |
| solstice rug (`0x00f286…`) | `0x626fca2cde3f34b49370cea604e971c0725615a6` | 2026-12-27 |
| samsung — FAST TEST (`0x6c63d5…`) | `0x83dCCCB6A83874773B893a1e2B277E8d4F254008` | ~1h after creation (full-cycle test) |

### Create a market (owner CLI)

```bash
cast send 0x6B8481401648f540fe87B6173d80E37D6B501313 \
  "createMarket(bytes32,uint64,uint64)" <termId> <resolutionDateUnix> <lockOffsetSecs> \
  --rpc-url https://rpc.intuition.systems --account intuition
```
