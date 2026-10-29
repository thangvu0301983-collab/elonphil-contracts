#!/usr/bin/env node
// Writes docs/EXACT-VERSION-EVIDENCE.md, the reviewer page, from the evidence that pack-exact packed, so every number
// on the page is the packed number. Run after pack-exact with the same VALID_AFTER and DEADLINE:
//   VALID_AFTER=... DEADLINE=... node programmable/evidence-page.mjs

import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const ev = JSON.parse(readFileSync(path.join(repo, "evidence/exact-version.json"), "utf8"));
const packed = readFileSync(path.join(repo, "protected/phil/evidence/exact-version.json"), "utf8");
if (packed !== readFileSync(path.join(repo, "evidence/exact-version.json"), "utf8")) throw new Error("evidence is not the packed evidence: run pack-exact first");
for (const k of ["VALID_AFTER", "DEADLINE"]) if (!process.env[k]) throw new Error("set " + k);

const s = ev.scenarios;
const need = (id) => { if (!s[id]?.passed) throw new Error("scenario missing or failed: " + id); return s[id]; };
const ib = need("initial-buy-bound-call"), p01 = need("P01-opening-fdv-floor"), p06 = need("P06-opening-tax-at-launch-second");
const a01 = need("A01-custom-accounting"), f01 = need("F01-platform-fee-exact"), l01 = need("L01-liquidity-custody-and-withdrawal");
const j01 = need("J01-phil-vault-jab-pool");
for (const id of Object.keys(s)) need(id);

const E18 = 10n ** 18n;
const group = (v) => String(v).replace(/\B(?=(\d{3})+(?!\d))/g, ",");
const eth = (wei, dp = 6) => { const w = BigInt(wei); const f = (w % E18).toString().padStart(18, "0").slice(0, dp).replace(/0+$/, ""); return (w / E18).toString() + (f ? "." + f : ""); };
const tok = (u) => group(BigInt(u) / E18) + "." + (BigInt(u) % E18).toString().padStart(18, "0").slice(0, 2);
const utc = (t) => new Date(Number(t) * 1000).toISOString().replace("T", " ").replace(/\.\d+Z$/, " UTC");
const va = process.env.VALID_AFTER, dl = process.env.DEADLINE;
if (BigInt(dl) - BigInt(va) !== 86_400n) throw new Error("permit window must be exactly 24 hours");

const page = `# ELON PHIL XXXL ($ELONPHILXXXL): exact-version evidence for review

This page summarizes the evidence for ELON PHIL XXXL's protected Ethereum launch. The machine-readable evidence is packed inside
the request as the attestation \`exact-version-execution-evidence\`
([\`protected/phil/evidence/exact-version.json\`](../protected/phil/evidence/exact-version.json)). It was produced by
[\`test/PhilExactVersion.fork.t.sol\`](../test/PhilExactVersion.fork.t.sol), and
[\`programmable/pack-exact.mjs\`](../programmable/pack-exact.mjs) reproduces it. This page is generated from that file
by [\`programmable/evidence-page.mjs\`](../programmable/evidence-page.mjs).

## Why the admission record says "static only"

The API accepts \`behaviorExecution\` only from Programmable's platform runtime executor, and caller-supplied proofs
cannot clear admission findings. On Ethereum the executor reports \`BEHAVIOR_RUNNER_NOT_CONFIGURED\`, so the
applicant cannot add runtime evidence to the admission record. It is provided here instead, bound to the exact request.

## How the evidence is bound to the exact version

1. \`export-exact-fixture.mjs\` reads the packed \`launch.json\` and produces the Router's graph targets with resolved
   init code and initializer calldata, in deployment order, plus the route namespace and nonce.
2. On an Ethereum mainnet fork (block ${ev.subject.forkBlock}), the test sends those exact targets to Programmable's
   GraphFactory (\`${ev.subject.graphFactory}\`), called as the 24h Router (\`${ev.subject.router}\`) with the launch
   wallet as \`tx.origin\`.
3. Every target is asserted at its predicted CREATE2 address with the packed runtime code hash.
4. Only the Router's permit signature check is not exercised.

The evidence file is part of the source bundle, which decides the addresses, so it records no target addresses. The
request is rebuilt and re-tested until the regenerated evidence is byte-identical to the packed file. Results:
${ev.tests.exactVersionPassed} of ${ev.tests.exactVersionPassed} exact-version scenarios pass, and ${ev.tests.allPassed} of ${ev.tests.allPassed + ev.tests.failed} repository tests pass.

## 1. Permit window

The permit is valid from \`validAfter\` = ${utc(va)} to \`deadline\` = ${utc(dl)}: 86,400 s, the 24h Router's
\`MAX_PERMIT_LIFETIME\`. The window opens about 24 hours after packing, so it covers the 24-hour review and then the
24-hour launch window.

## 2. Initial buy: bound call, observed input and output

| Item | Value |
|---|---|
| Bound call | \`initialize(hook, token, ${ib.startTick}, developer, ${ib.minimumTokensOut})\`, value ${eth(ib.initialBuyInputWei)} ETH, executed by the GraphFactory in the launch transaction |
| Observed input | ${group(ib.initialBuyInputWei)} wei |
| Observed output | ${group(ib.initialBuyTokensOut)} ELONPHILXXXL units (${tok(ib.initialBuyTokensOut)} ELONPHILXXXL) to the developer, at or above the minimum and below the 2% cap (${group(BigInt(ib.walletTokenLimit) / E18)} ELONPHILXXXL) |
| Fees | platform ${group(ib.platformFee)} wei; creator ${group(ib.creatorFee)} wei; opening tax ${ib.openingTax} (developer exempt) |
| Opening price | FDV USD ${group(ib.openingFdvUsd)} at tick ${ib.startTick} |
| Feed | Chainlink ETH/USD answer ${p01.observedEthUsdAnswer}, ${group(ib.feedAgeSecondsAtLaunch)} s old (limit ${group(ib.maxFeedAgeSeconds)} s) |
| Floor | Launch passes while the answer is at least ${p01.minimumEthUsdAnswerForLaunch} (${(Number(p01.priceDropToleranceBps) / 100).toFixed(2)}% below); one unit lower reverts with \`OpeningValuationTooLow\` |
| Oversized buy | A ${eth(need("P03-initial-buy-above-2pct-reverts").attemptedInitialBuyWei)} ETH opening buy reverts the whole graph (\`BuyerLimitExceeded\`) |
| Short buy | A ${eth(need("P04-initial-buy-minimum-output").attemptedInitialBuyWei)} ETH buy misses the bound minimum and reverts (\`InvalidInitialBuy\`) |

## 3. Twelve protection scenarios (P01–P12)

| # | Scenario | Result |
|---|---|---|
| P01 | USD 15,000 floor | Reverts one feed unit below the floor; passes at it |
| P02 | Fresh oracle | Feed older than 3,600 s reverts (\`InvalidOraclePrice\`); exactly 3,600 s is accepted |
| P03 | 2% opening-buy cap | Oversized opening buy reverts atomically; nothing is deployed |
| P04 | Minimum output | Underfunded buy reverts |
| P05 | Single atomic initialization | Initializer callable only by the GraphFactory, once; the pool cannot be re-initialized or cloned; the graph authorization cannot be replayed |
| P06 | 99% opening fee | ${eth(p06.buyAtLaunchSecond.grossNative)} ETH buy at second 0: opening tax ${eth(p06.buyAtLaunchSecond.openingTax, 8)} ETH, platform ${eth(p06.buyAtLaunchSecond.platformFee, 8)} ETH, creator ${eth(p06.buyAtLaunchSecond.creatorFee, 8)} ETH (${group(p06.totalBuyFeePpm)} ppm) |
| P07 | Linear decay | Exact surcharge at seconds 1, 10, 20 and 29; zero from second 30 |
| P08 | Developer | Exempt from the surcharge but still capped: an over-cap buy reverts (\`BuyerLimitExceeded\`) |
| P09 | Cumulative buyer cap | Second buy over 2% reverts; selling does not refill the budget |
| P10 | Recipient cap | Over-cap transfer reverts (\`WalletLimitExceeded\`); forwarding does not refill |
| P11 | Canonical router only | For 300 s, buys through a test router or a raw PoolManager integration revert (\`UnsupportedRouter\`); the Universal Router works; sells use any route at normal fees |
| P12 | Expiry | Still protected at second 299; at second 300 a buy above 2% and a transfer above 2% succeed |

## 4. Swaps, liquidity, callbacks, accounting and the 0.3% fee

- **Four swap quadrants** (S01) and **a second user over time** (S02): exact-in and exact-out buys and sells at three
  sizes, interleaved users across 30 days and a year; every fee matches an independent reimplementation of the fee
  formula (gross native ETH, ceil per trade).
- **Liquidity custody and withdrawal** (L01): the seed position (liquidity ${group(l01.lockedLiquidity)}) belongs to
  the initializer, which has no withdrawal entry point. A third-party LP adds and fully withdraws, losing at most
  ${l01.thirdPartyEthRoundingLoss} wei of rounding on each side.
- **Callback authentication** (C01): hook callbacks revert unless called by the PoolManager; \`afterSwap\` is bound to
  the active swap; the module is kernel-only; fee vaults reject non-kernel records and unbound callbacks.
- **Custom accounting** (A01): recorded fees are backed one-to-one by PoolManager ERC-6909 claims; supply is conserved;
  an exact-output buy sent with 10 ETH pays exactly its gross (${eth(a01.exactOutputBuyWith10EthSent.grossNative, 18)} ETH)
  and gets the rest refunded. Claims are caller-independent and reach only the fixed recipients: creator fees go to the
  Phil Vault, platform fees and the opening tax to the treasury.
- **Exact 0.3% platform fee** (F01): the same trades through the Universal Router, a v4 test router and a raw
  PoolManager integration each pay exactly \`ceil(gross × 30 / 10000)\`: ${group(f01.platformFeePpmOfGross)} ppm of
  ${eth(f01.grossNativeTotal, 2)} ETH gross, no bypass and no overcharge.

## 5. Phil Vault and the Jab Pool (J01, A01)

The Phil Vault is the fourth graph target and the hook's immutable creator-fee recipient. On the exact deployed
vault:

- \`distribute()\` (anyone) pays 80% to the project treasury wallet and keeps 20% as the Jab Pool
  (A01: ${eth(a01.vaultPaidOut)} ETH paid out, ${eth(a01.vaultJabPool)} ETH kept).
- Only the Phil AI agent wallet can pay a reward from the Jab Pool, once per jab id with the hash of the rewarded post,
  at most 10% of the pool per reward and 25% per day, and never to the treasury wallet, the guardian, the agent or the
  vault (J01: ${eth(j01.rewardPaid)} ETH paid from a ${eth(j01.jabPoolFunded)} ETH pool).
- The guardian can pause and unpause the agent at once; pausing moves no ETH.
- Changing the treasury wallet, the agent or the guardian takes a 48-hour public timelock. There is no other way to move
  ETH out of the vault.

The agent's key runs on a server. If it is stolen, the caps limit the loss to 25% of the Jab Pool per day until the
guardian pauses it. The project description in the request states this, and states who holds each role.

## Reproduce

Place the submitted bytes at \`protected/launch.json\` with its config, then run:

\`\`\`bash
PL_DIR=<@programmable/launch 4.1.7> node programmable/export-exact-fixture.mjs
mkdir -p evidence/exact
ETH_RPC_URL=<archive RPC> FORK_BLOCK=${ev.subject.forkBlock} forge test --json > forge.json
FORK_BLOCK=${ev.subject.forkBlock} node programmable/collect-exact-evidence.mjs forge.json
\`\`\`

\`evidence/exact-version.json\` then matches the packed \`phil/evidence/exact-version.json\` byte for byte.
`;
mkdirSync(path.join(repo, "docs"), { recursive: true });
writeFileSync(path.join(repo, "docs/EXACT-VERSION-EVIDENCE.md"), page);
console.log("wrote docs/EXACT-VERSION-EVIDENCE.md");
