# DoraHacks submission: Tapster

## Name
Tapster

## One-liner (BUIDL tagline)
Staked, slashable price feeds for gno.land: reporters earn for accuracy, lose stake for lying, and any realm reads prices for free.

## Tags
Crypto / Web3 · DeFi · Gno · Infrastructure

## Links (fill after deploy)
- Oracle realm (gnoweb): https://onyx.testnets.gno.land/r/<ADDR>/tapster/v0
- Demo consumer (gnoweb): https://onyx.testnets.gno.land/r/<ADDR>/tab/v0
- Math package: https://onyx.testnets.gno.land/p/<ADDR>/tapmath/v0
- Web app: <hosted URL>?ns=<ADDR>
- Repository: https://github.com/<you>/tapster
- Demo video: <YouTube/Loom link>

## Description

**The problem.** gno.land has no price oracle. Any app that charges in dollars, lends against collateral, triggers a stop-loss or settles a bet on a price either trusts a single operator or can't be built. The other hackathon entries are escrows, games and tools. None of them can read a price.

**What Tapster is.** A staked oracle realm with four live feeds (GNOT-USD, BTC-USD, ETH-USD, XAU-USD).

- Reporters stake GNOT and submit one price per round.
- The answer is the **stake-weighted median**, so moving it costs half of all staked weight.
- Reporters within 1% earn from a reward pool. Reporters more than 5% off lose 5% of their stake, which refills the pool. Honest reporters are paid by dishonest ones.
- Rounds close lazily on the next report or a public `Finalize`, so there are no keepers and no backend.
- Reads are free: `tapster.PriceFresh("GNOT-USD", 600)` returns a price only if it is fresh.

**Proof it's useful: Tab.** A second realm imports Tapster to run bar tabs priced in dollars and paid in GNOT. At payment time it converts the bill at the live price, refuses stale data, pays the bartender exactly what is due and refunds the rest. Tab registers itself on-chain as a Tapster consumer, which the oracle's page lists under "Used by".

**Built the Gno way.**
- The realm renders its own dashboard on gnoweb: feed table with SVG sparklines, per-feed price chart, last round's reports with accurate/slashed badges, reporter leaderboard, activity log and an integration guide. Every action has a transaction link.
- `p/tapmath` is a reusable, float-free package: weighted median, deviation in basis points, payer-safe USD↔ugnot conversion.
- It follows the Gno security guide. Payment entry points pair `IsUserCall()` with `OriginSend()`, with regression tests for the intermediate-realm and `maketx run` bypasses. Reads return values, never pointers. The admin is bounded: slashing is capped at 20% and the admin can never touch stake. Stake stays slashable while unbonding, and `Withdraw` settles or blocks on open rounds, so a reporter can't lie and run.

**Shipped with it.**
- A no-dependency Node reporter bot. It takes the median of CoinGecko, Kraken, Coinbase, OKX and KuCoin, and skips any round where the exchanges disagree, so honest reporters are never slashed for a bad source. A chaos mode demonstrates slashing live.
- A web app that reads the chain over RPC and signs with Adena: live cards, interactive charts, staking, claiming, funding and the Tab flow.
- A one-command `deploy.sh` that verifies gnokey's checksum, deploys in dependency order and waits for onyx's approver.
- 28 tests across the three packages, plus a full run on a local chain: 3 reporters over many rounds, a live slash that dropped the liar below minimum stake and locked him out, and a Tab paid with exact on-chain balances.

**After the hackathon (Builder Retention).** Deploy to mainnet, publish monthly releases, add pairs (SOL, NGN-USD, a USDC peg monitor) and a TWAP client package. Onboard other builders as consumers; the wagers, bounty and game realms in this hackathon can all price in dollars with one import.

## Judging criteria map
- **Technical quality (40%).** Stake-weighted median, slashing, rewards and unbonding with escape protection. Security-guide patterns, 28 tests, checked on a live chain.
- **User appeal (20%).** Live charts on gnoweb and in the web app, plus a consumer app people understand at a glance.
- **Creativity (20%).** The only oracle in the field. Honest reporters are paid by liars' stake.
- **Docs & demo (20%).** README with an integration guide, an in-realm `:integrate` page, and a 3-minute video.

---

# Demo video script (about 3 minutes)

Record with QuickTime (File → New Screen Recording). Keep the bot running with `CHAOS_KEY=tapster-r3` so a slash happens on camera. For a faster video, set 60-second rounds first:
`gnokey maketx call -pkgpath gno.land/r/<ADDR>/tapster/v0 -func SetFeedParams -args GNOT-USD -args 60 -args 2 -args 100 -args 500 -args 500 -args 2000 ... tapster-admin`

| Time | Screen | Say |
|---|---|---|
| 0:00 | Tapster web app, feed cards | "gno.land has a DEX, wallets and DAOs, but no price oracle. Tapster is one: staked, slashable price feeds any realm can read for free." |
| 0:20 | Terminal: bot log | "Reporters stake GNOT and run this bot. It takes the median of five exchanges and skips rounds where they disagree." |
| 0:40 | gnoweb `tapster/v0` | "Everything here is rendered by the realm itself on gnoweb: prices, spreads, reward pools, trend lines. No backend." |
| 1:00 | gnoweb `:feed/GNOT-USD`, last round table | "Each round, the answer is the stake-weighted median. Reporters within 1% earn. This one reported 30% high…" |
| 1:15 | Slashed badge + Recent slashes + `:reporters` | "…and lost 5% of his stake, which went into the reward pool. Honest reporters are paid by dishonest ones. Drop below the minimum and you're locked out." |
| 1:40 | Code: `Withdraw` + `settlePending` | "You can't lie and leave: stake stays slashable while unbonding, and withdraw settles your open rounds first." |
| 2:00 | Web app Tab demo: open, add items, Pay in Adena | "Here's a realm using it. Tab prices a bar bill in dollars, converts at the live GNOT price, refuses stale data, pays the bartender exactly and refunds the change." |
| 2:30 | gnoweb `:integrate` | "Integrating takes two imports and one call: MustPriceFresh. Your realm can register as a consumer on-chain." |
| 2:45 | Feed cards | "Tapster: price feeds on tap for gno.land. Next is mainnet, more pairs and more consumers." |
