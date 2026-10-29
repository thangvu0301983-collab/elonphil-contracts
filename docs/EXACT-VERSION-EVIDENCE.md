# ELON PHIL XXXL ($ELONPHILXXXL): exact-version evidence for review

This page summarizes the evidence for ELON PHIL XXXL's protected Ethereum launch. The machine-readable evidence is packed inside
the request as the attestation `exact-version-execution-evidence`
([`protected/phil/evidence/exact-version.json`](../protected/phil/evidence/exact-version.json)). It was produced by
[`test/PhilExactVersion.fork.t.sol`](../test/PhilExactVersion.fork.t.sol), and
[`programmable/pack-exact.mjs`](../programmable/pack-exact.mjs) reproduces it. This page is generated from that file
by [`programmable/evidence-page.mjs`](../programmable/evidence-page.mjs).

## Why the admission record says "static only"

The API accepts `behaviorExecution` only from Programmable's platform runtime executor, and caller-supplied proofs
cannot clear admission findings. On Ethereum the executor reports `BEHAVIOR_RUNNER_NOT_CONFIGURED`, so the
applicant cannot add runtime evidence to the admission record. It is provided here instead, bound to the exact request.

## How the evidence is bound to the exact version

1. `export-exact-fixture.mjs` reads the packed `launch.json` and produces the Router's graph targets with resolved
   init code and initializer calldata, in deployment order, plus the route namespace and nonce.
2. On an Ethereum mainnet fork (block 26297210), the test sends those exact targets to Programmable's
   GraphFactory (`0xB012e4A8F2c5FC4E8E4faCA9D5Ad6FfF13FBA887`), called as the 24h Router (`0xBE4bF6Ac8c6F012E1C8f25747A9fBccB2FDAC4C3`) with the launch
   wallet as `tx.origin`.
3. Every target is asserted at its predicted CREATE2 address with the packed runtime code hash.
4. Only the Router's permit signature check is not exercised.

The evidence file is part of the source bundle, which decides the addresses, so it records no target addresses. The
request is rebuilt and re-tested until the regenerated evidence is byte-identical to the packed file. Results:
20 of 20 exact-version scenarios pass, and 35 of 35 repository tests pass.

## 1. Permit window

The permit is valid from `validAfter` = 2026-10-30 09:15:38 UTC to `deadline` = 2026-10-31 09:15:38 UTC: 86,400 s, the 24h Router's
`MAX_PERMIT_LIFETIME`. The window opens about 24 hours after packing, so it covers the 24-hour review and then the
24-hour launch window.

## 2. Initial buy: bound call, observed input and output

| Item | Value |
|---|---|
| Bound call | `initialize(hook, token, 187260, developer, 6513655233069347034920449)`, value 0.05 ETH, executed by the GraphFactory in the launch transaction |
| Observed input | 50,000,000,000,000,000 wei |
| Observed output | 6,579,449,730,373,077,813,050,959 ELONPHILXXXL units (6,579,449.73 ELONPHILXXXL) to the developer, at or above the minimum and below the 2% cap (20,000,000 ELONPHILXXXL) |
| Fees | platform 150,000,000,000,000 wei; creator 1,000,000,000,000,000 wei; opening tax 0 (developer exempt) |
| Opening price | FDV USD 17,045 at tick 187260 |
| Feed | Chainlink ETH/USD answer 231096199548, 1,512 s old (limit 3,600 s) |
| Floor | Launch passes while the answer is at least 203368237288 (11.99% below); one unit lower reverts with `OpeningValuationTooLow` |
| Oversized buy | A 0.5 ETH opening buy reverts the whole graph (`BuyerLimitExceeded`) |
| Short buy | A 0.045 ETH buy misses the bound minimum and reverts (`InvalidInitialBuy`) |

## 3. Twelve protection scenarios (P01–P12)

| # | Scenario | Result |
|---|---|---|
| P01 | USD 15,000 floor | Reverts one feed unit below the floor; passes at it |
| P02 | Fresh oracle | Feed older than 3,600 s reverts (`InvalidOraclePrice`); exactly 3,600 s is accepted |
| P03 | 2% opening-buy cap | Oversized opening buy reverts atomically; nothing is deployed |
| P04 | Minimum output | Underfunded buy reverts |
| P05 | Single atomic initialization | Initializer callable only by the GraphFactory, once; the pool cannot be re-initialized or cloned; the graph authorization cannot be replayed |
| P06 | 99% opening fee | 0.01 ETH buy at second 0: opening tax 0.00967 ETH, platform 0.00003 ETH, creator 0.0002 ETH (990,000 ppm) |
| P07 | Linear decay | Exact surcharge at seconds 1, 10, 20 and 29; zero from second 30 |
| P08 | Developer | Exempt from the surcharge but still capped: an over-cap buy reverts (`BuyerLimitExceeded`) |
| P09 | Cumulative buyer cap | Second buy over 2% reverts; selling does not refill the budget |
| P10 | Recipient cap | Over-cap transfer reverts (`WalletLimitExceeded`); forwarding does not refill |
| P11 | Canonical router only | For 300 s, buys through a test router or a raw PoolManager integration revert (`UnsupportedRouter`); the Universal Router works; sells use any route at normal fees |
| P12 | Expiry | Still protected at second 299; at second 300 a buy above 2% and a transfer above 2% succeed |

## 4. Swaps, liquidity, callbacks, accounting and the 0.3% fee

- **Four swap quadrants** (S01) and **a second user over time** (S02): exact-in and exact-out buys and sells at three
  sizes, interleaved users across 30 days and a year; every fee matches an independent reimplementation of the fee
  formula (gross native ETH, ceil per trade).
- **Liquidity custody and withdrawal** (L01): the seed position (liquidity 85,882,379,230,666,082,090,301) belongs to
  the initializer, which has no withdrawal entry point. A third-party LP adds and fully withdraws, losing at most
  1 wei of rounding on each side.
- **Callback authentication** (C01): hook callbacks revert unless called by the PoolManager; `afterSwap` is bound to
  the active swap; the module is kernel-only; fee vaults reject non-kernel records and unbound callbacks.
- **Custom accounting** (A01): recorded fees are backed one-to-one by PoolManager ERC-6909 claims; supply is conserved;
  an exact-output buy sent with 10 ETH pays exactly its gross (0.036785366201247561 ETH)
  and gets the rest refunded. Claims are caller-independent and reach only the fixed recipients: creator fees go to the
  Phil Vault, platform fees and the opening tax to the treasury.
- **Exact 0.3% platform fee** (F01): the same trades through the Universal Router, a v4 test router and a raw
  PoolManager integration each pay exactly `ceil(gross × 30 / 10000)`: 3,000 ppm of
  21.72 ETH gross, no bypass and no overcharge.

## 5. Phil Vault and the Jab Pool (J01, A01)

The Phil Vault is the fourth graph target and the hook's immutable creator-fee recipient. On the exact deployed
vault:

- `distribute()` (anyone) pays 80% to the project treasury wallet and keeps 20% as the Jab Pool
  (A01: 0.046062 ETH paid out, 0.011515 ETH kept).
- Only the Phil AI agent wallet can pay a reward from the Jab Pool, once per jab id with the hash of the rewarded post,
  at most 10% of the pool per reward and 25% per day, and never to the treasury wallet, the guardian, the agent or the
  vault (J01: 0.00202 ETH paid from a 0.0202 ETH pool).
- The guardian can pause and unpause the agent at once; pausing moves no ETH.
- Changing the treasury wallet, the agent or the guardian takes a 48-hour public timelock. There is no other way to move
  ETH out of the vault.

The agent's key runs on a server. If it is stolen, the caps limit the loss to 25% of the Jab Pool per day until the
guardian pauses it. The project description in the request states this, and states who holds each role.

## Reproduce

Place the submitted bytes at `protected/launch.json` with its config, then run:

```bash
PL_DIR=<@programmable/launch 4.1.7> node programmable/export-exact-fixture.mjs
mkdir -p evidence/exact
ETH_RPC_URL=<archive RPC> FORK_BLOCK=26297210 forge test --json > forge.json
FORK_BLOCK=26297210 node programmable/collect-exact-evidence.mjs forge.json
```

`evidence/exact-version.json` then matches the packed `phil/evidence/exact-version.json` byte for byte.
