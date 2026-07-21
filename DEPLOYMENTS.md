# Deployments

## Intuition mainnet (chain 1155) — TEST deployment, 2026-07-21

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

### Create a market (owner CLI)

```bash
cast send 0x6B8481401648f540fe87B6173d80E37D6B501313 \
  "createMarket(bytes32,uint64,uint64)" <termId> <resolutionDateUnix> <lockOffsetSecs> \
  --rpc-url https://rpc.intuition.systems --account intuition
```
