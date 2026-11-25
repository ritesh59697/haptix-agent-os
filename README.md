<div align="center">
  <h2>Haptix</h2>
  <p><strong>Spending limits your AI agent can't talk its way past.</strong></p>
  <p>On-chain guards for Binance Agentic Wallets, keyed to Agent ID, on BNB Chain mainnet.</p>
  <p>
    <a href="https://haptix-agent-os.vercel.app/join"><strong>Try it (Agent ID holders)</strong></a> •
    <a href="https://haptix-agent-os.vercel.app/agent-id"><strong>Website</strong></a> •
    <a href="skills/haptix/SKILL.md"><strong>Agent skill</strong></a> •
    <a href="#contracts-bnb-chain-mainnet"><strong>Contracts</strong></a>
  </p>
</div>

This repo holds two entries:

- **[Haptix for Agent ID](#haptix-for-agent-id)**, the entry for the Agent ID Hackathon (Binance Wallet × BNB Chain, Nov 18 – Dec 9, 2026). It's live on BNB Chain mainnet. Its code is in `src/agentid/`, `test/agentid/`, `skills/haptix/` and `web/`.
- **[Haptix Enclave](#haptix-enclave-for-binance-agent-os)**, the earlier ERC-4337 passkey account, which won Track A of the Binance Agent OS Mini Hackathon.

---

## Haptix for Agent ID

### The problem

An Agentic Wallet does what its agent asks. The agent reads prompts from emails, web pages and other agents, and one injected line can tell it to pay someone. Binance's preview-and-confirm step helps, but it sits in the agent's skill and conversation. A user who's tired, rushed or talked into it can still say yes to the wrong thing.

### What Haptix does

Haptix moves the limits out of the conversation and into contracts on BNB Chain. Only Agent ID holders can use them:

| | |
|---|---|
| **Daily cap** | The most the agent may pay out of the vault per day, per token. |
| **Per-payment ceiling** | No single payment above this, ever. |
| **Passkey threshold** | Payments above it also need the owner's device passkey (WebAuthn, verified on-chain through BNB Chain's P-256 precompile). |
| **Recipients** | Only other Agent ID holders (`.ai` names), or addresses the owner gave a daily allowance. |
| **Raise delay** | Lowering a limit is instant. Raising one, adding a recipient or changing the passkey is queued on-chain and applies only after the owner's own delay (for example 24h), so a hijacked prompt can't quietly lift a limit and spend in the same breath. Queued changes are public and cancellable. |
| **Withdrawals** | Taking money back out of the vault waits the same delay, or happens at once with a passkey approval. That stops a hijacked agent from emptying the vault into the wallet and spending it there. |

**Agent ID is the core of the design, not decoration.** Haptix uses it in all three of the ways the hackathon lists:

- **Access control:** `open`, `deposit` and `claim` check `AgentID.balanceOf(msg.sender) > 0` on-chain.
- **Identity:** the vault pays only Agent ID holders by default. Anyone else needs an allowance that waits out the delay.
- **Payments:** agent-to-agent payments between `.ai` names, each one checked against the payer's guard.

Every action comes straight from the holder's Agentic Wallet (`baw contract-call` in Developer Mode). So `msg.sender` is always the Agent ID holder, with no relayer, bundler or session server in between.

### How someone uses it

There's no website sign-in: Agentic Wallets can't connect to sites, and Haptix doesn't want them to. The user talks to their own agent:

1. Claim an Agent ID in the Binance App, turn on Developer Mode, and keep a little BNB for gas.
2. Install two skills: Binance's `binance-agentic-wallet`, which signs and sends, and [`skills/haptix`](skills/haptix/SKILL.md), which builds and simulates the Haptix calls and never signs anything.
3. Ask the agent, for example: *"Open a Haptix guard for USDT: 5 a day, at most 2 per payment, passkey above 1, and make any increase wait 24 hours."*

For each write, the skill simulates the call, then runs `baw contract-call preview`, and the user sees Binance's preview and confirms. When a payment or instant withdrawal needs a passkey, the skill gives the user an approval link ([`/approve`](web/approve.html)). They check the amount and recipient on their own device, approve with fingerprint or face, and paste the code back.

The fastest way in is **[/join](https://haptix-agent-os.vercel.app/join)**. It's one prompt that opens a starter guard (USDT: 5 a day, 2 per payment, 24h raise delay) and claims the **Guarded Agent badge**: a soulbound NFT whose artwork is drawn on-chain from the holder's live guard. That's two transactions, gas only, and no money moves. The page shows a live wall of badge holders and a progress check by address.

### Tested on mainnet with real USDT

The first vault run, on Nov 25, 2026. Every step was confirmed by the owner in the Binance Agentic Wallet preview.

| Step | Result | Tx |
|---|---|---|
| Pay 1 USDT to another Agent ID holder (`syther069.ai`), under the passkey threshold | Paid | [`0x5ccd42d2…a049`](https://bscscan.com/tx/0x5ccd42d2934c4839eec107e5bb8b3818bb59ffe4d7b4d680edc3113439bca049) |
| Try to pay 1.5 USDT, above the threshold | Refused in simulation: `PasskeyRequired` | — |
| Same payment, approved with the owner's device passkey | Paid | [`0xf8564377…3f4c`](https://bscscan.com/tx/0xf85643772635eb2f459da4536550d945455d790a1a1ae3402267475890a43f4c) |
| Withdraw the remaining 0.5 USDT instantly, with the passkey | Withdrawn | [`0xc672962a…262d`](https://bscscan.com/tx/0xc672962aecea19324c37848c8cc096ea8f345f7cfa3c35edb52ae215870d262d) |

### Contracts (BNB Chain mainnet)

All four are verified and open source on BscScan. **None has an owner, admin, pause, upgrade path, mint authority or fee.** Nobody, including the deployer, can change a rule, move a user's funds or freeze anything. Only the holder can change their own guard, and only under the delay rules above.

| Contract | Address | What it does |
|---|---|---|
| HaptixRegistry (v2) | [`0xF2aD0c1fD648A4a556872456ce5BBCE97E9e8e1f`](https://bscscan.com/address/0xF2aD0c1fD648A4a556872456ce5BBCE97E9e8e1f#code) | Guards and limits per holder, queued changes (apply window 7 days, at most 8 pending) |
| HaptixVault | [`0x01Cf3189f7a681073081b3Fca520512EB67E26Ca`](https://bscscan.com/address/0x01Cf3189f7a681073081b3Fca520512EB67E26Ca#code) | Deposits, guarded payments, passkey approvals, delayed or passkey withdrawals (24h spend window, 3-day withdrawal window) |
| HaptixBadge | [`0xD88e147C02f4E0eD93A67d043Ef31AC4DDbf253A`](https://bscscan.com/address/0xD88e147C02f4E0eD93A67d043Ef31AC4DDbf253A#code) | Soulbound "Guarded Agent" badge, one per holder with an open guard, on-chain SVG |
| HaptixRegistry (v1) | [`0x6C33A3d5d64862671F5BF9139920541a6BC4F73b`](https://bscscan.com/address/0x6C33A3d5d64862671F5BF9139920541a6BC4F73b#code) | The first version, from the go/no-go spike on Nov 18; superseded by v2 |

All of them read Agent ID from the official contract [`0x60b9262456de011f7d15a54cdd8c48baaa8b022f`](https://bscscan.com/address/0x60b9262456de011f7d15a54cdd8c48baaa8b022f).

### Safety rules we built to

| Hackathon red line | How Haptix meets it |
|---|---|
| No web QR or pairing-code login | No web login of any kind. The user's own agent sends everything through `baw`. |
| Skills must not bypass confirmation | The skill's first hard rule: never `execute` without the user's explicit yes to Binance's preview. The helper script can't sign. |
| No unauthorized transfers or unlimited approvals | Deposits use an exact-amount approval. The vault only moves funds on the holder's own call, within their guard. |
| Open source, owner permissions disclosed | Verified on BscScan. No owner permissions exist (see above). |
| No Binance or BNB branding | The project is called Haptix. |
| No collecting credentials | Haptix never sees a seed phrase, private key, API secret or pairing code. The passkey stays on the user's device; only its public key is stored on-chain. |
| No promised returns; risk warnings | There's no yield. The website and `/join` both carry a risk warning, and the passkey page warns against approving anything you didn't ask for. |
| No "look up wallets by name" | Haptix has no name-lookup feature. The skill resolves a `.ai` name only for a payment the user is making, through Binance's own command, and asks the user to confirm the address. |

### What's honest to know

- **Only money in the vault is protected.** Haptix can't limit what the Agentic Wallet spends directly; the skill says so when asked.
- **Experimental and not externally audited.** Keep only small amounts in any agent-controlled wallet.

### Build and test

```bash
forge test --match-path "test/agentid/*"   # 68 tests: registry, vault (incl. real WebAuthn vectors), badge
node skills/haptix/scripts/haptix.mjs status --address <0x…>   # read any guard; needs only Node 18
```

- **Fork tests:** they run against the live mainnet contracts when `BSC_RPC_URL`, `HAPTIX_REGISTRY` and the sample-holder variables in [`.env.example`](.env.example) are set.
- **Deploys:** `scripts/deploy-agentid.sh` and `scripts/deploy-badge.sh` take every address and window from the environment.

---

<a id="haptix-enclave-for-binance-agent-os"></a>
<div align="center">

  <h2>Haptix Enclave for Binance Agent OS</h2>
  <p><strong>The Biometric Hardware Enclave & On-Chain Security Firewall for Autonomous AI Agents.</strong></p>
  <p><em>Official Submission for the Binance Agent OS Mini Hackathon — Track A: Build an AI Agent</em></p>
  <p>🏆 <strong>Winner, Track A (300 USDC)</strong> — <a href="https://x.com/binance/status/2109750965570060759">Binance's winner announcement</a></p>
  <p>
    <a href="https://haptix-agent-os.vercel.app/grant-session"><strong>🚀 Live Console</strong></a> •
    <a href="https://haptix-agent-os.vercel.app"><strong>🌐 Website</strong></a> •
    <a href="https://x.com/Ritesh5969/status/2097242750379077915?s=20"><strong>📹 Demo Video (X / Twitter)</strong></a> •
    <a href="https://testnet.bscscan.com/address/0xE12c6D4a5a40A75885BB4b7503F76C1e41C306C5"><strong>📜 BNB Testnet Contract</strong></a>
  </p>
</div>

---

## Executive Summary

Binance built **Agent OS** to connect AI agents to deep market liquidity, live order books, and trading capabilities under strictly controlled permissions. However, by design, **Binance Agentic sub-accounts have no withdrawal permissions and do not execute on-chain DeFi transactions**.

**Haptix provides the missing on-chain security layer:**
When an AI agent uses Binance Agent OS for market intelligence and needs to execute hedges, rebalancing, or arbitrage on-chain, **Haptix enforces hardware-backed spending policies** directly inside an ERC-4337 smart account:

1. **Tier 1 (Autonomous <= $50 USDC)**: The AI agent executes headlessly on **BNB Smart Chain** (and Base Sepolia) using delegated session keys (`0x01` signature) with **Zero Human Prompts**.
2. **Tier 2 (Escalated $50 - $200 USDC)**: If market volatility prompts a larger rebalance, the transaction is **intercepted on-chain** and requires a **2-of-2 WebAuthn Passkey Quorum** (Apple Touch ID / Secure Enclave).
3. **Tier 3 (Hard Ceiling > $200 USDC)**: If the agent is compromised or hallucinates a rogue trade, the smart account **fails closed and reverts on-chain** before funds can move.

---

## Dual-Layer Architecture

```
                               +---------------------------------------+
                               |     Binance Agent OS MCP Gateway      |
                               |   (https://agent.binance.com/mcp)     |
                               |   - Live Order Book & Spreads         |
                               |   - 24h Price & Volatility Ticker     |
                               +---------------------------------------+
                                                   |
                                     (1) Live Market Intelligence
                                                   v
                               +---------------------------------------+
                               |            LLM Agent Core             |
                               |  - Evaluates CeFi vs DeFi Spreads     |
                               |  - Determines Hedge/Rebalance Size    |
                               +---------------------------------------+
                                                   |
                                     (2) Dispatches Scoped UserOp
                                                   v
                               +---------------------------------------+
                               |      Haptix Session Key Manager       |
                               |  - Signs with Agent ECDSA Key (0x01)  |
                               |  - Evaluates Pre-Flight SpendPolicy   |
                               +---------------------------------------+
                                                   |
                                     (3) Broadcast to EntryPoint v0.7
                                                   v
                               +---------------------------------------+
                               |     BNB Smart Chain Smart Account     |
                               |   PasskeyAccount.sol (ERC-4337 v0.7)  |
                               |   - Tier 1: Autonomous (< $50)        |
                               |   - Tier 2: Biometric Touch ID Quorum |
                               |   - Tier 3: Hard Ceiling Block (> $200)|
                               +---------------------------------------+
```

---

## Quick Start & Judge Demo (1 Command)

Run the end-to-end Binance Agent OS live intelligence & execution cycle:

```bash
# Run the live Binance Agent OS AI Agent Demo
npm run demo:binance
```

### What this demo demonstrates live:
1. **Live Binance Agent OS Connection**: Fetches real-time price feeds, 24h momentum, and top-of-book bid/ask spreads from Binance.
2. **LLM Decision Engine**: Evaluates market conditions and dynamically targets an autonomous micro-hedge.
3. **Tier 1 Autonomous Execution**: Signs and constructs an ERC-4337 UserOperation with signature mode `0x01` (zero passkey prompts).
4. **Tier 2 Volatility Escalation**: Simulates a volatility spike attempting a $150 transaction, proving that execution pauses and demands a hardware Touch ID passkey quorum.
5. **Tier 3 Hard Ceiling Firewall**: Proves that a rogue $350 transaction is blocked dead on-chain.

---

## Full Test Suites (293 Tests Passing)

```bash
# Run the complete TypeScript SDK test suite (50 tests passing)
npm run test:sdk

# Smart contract test suite with RIP-7212 P-256 precompile tests (243 tests passing)
forge test
```

---

## Live Deployments (Multi-Chain: BNB Chain & Base Sepolia)

### 1. BNB Smart Chain Testnet (ChainId 97) — *Binance Ecosystem Native*

| Parameter | Value |
|---|---|
| **Live Smart Account** | [`0xE12c6D4a5a40A75885BB4b7503F76C1e41C306C5`](https://testnet.bscscan.com/address/0xE12c6D4a5a40A75885BB4b7503F76C1e41C306C5) |
| **PasskeyAccountFactory** | [`0x3Bc2B099EB7D4622fB95Cb46Af5525825b809c8d`](https://testnet.bscscan.com/address/0x3Bc2B099EB7D4622fB95Cb46Af5525825b809c8d) |
| **Implementation** | [`0x6d601Fc9e269bA238b1227b40cB4d67F777867A5`](https://testnet.bscscan.com/address/0x6d601Fc9e269bA238b1227b40cB4d67F777867A5) |
| **Canonical EntryPoint** | [`0x0000000071727De22E5E9d8BAf0edAc6f37da032`](https://testnet.bscscan.com/address/0x0000000071727De22E5E9d8BAf0edAc6f37da032) (ERC-4337 v0.7) |
| **Enrolled Hardware Signers** | 2 Hardware Passkeys (Touch ID Apple Secure Enclave & iCloud Keychain) |

### 2. Base Sepolia (ChainId 84532)

| Parameter | Value |
|---|---|
| **Live Smart Account** | [`0xB01543453cF31052c769d79e9C755E3b035d796f`](https://sepolia.basescan.org/address/0xB01543453cF31052c769d79e9C755E3b035d796f) |
| **PasskeyAccountFactory** | [`0x1bB7cCf96cB211045982fC8a0069D9C0d718B83b`](https://sepolia.basescan.org/address/0x1bB7cCf96cB211045982fC8a0069D9C0d718B83b) |
| **Canonical EntryPoint** | [`0x0000000071727De22E5E9d8BAf0edAc6f37da032`](https://sepolia.basescan.org/address/0x0000000071727De22E5E9d8BAf0edAc6f37da032) (ERC-4337 v0.7) |
| **Enrolled Hardware Signers** | 2 Hardware Passkeys (Touch ID Apple Secure Enclave & iCloud Keychain) |
| **Verified Autonomous UserOp** | [`0x4ca3ea90…5840`](https://sepolia.basescan.org/tx/0x4ca3ea90dfa75ceef593c381a75b6cab9e36188fc03db26ccf064e2ca9785840) (Block 46457806) |
| **On-Chain Policy Rejection Proof** | Over-limit transfer rejected on-chain: `SIG_VALIDATION_FAILED (1)` & EntryPoint `AA24` |

---

## How It Works: The 3-Tier Enforcement Engine

The on-chain smart account intercepts calldata inside `validateUserOp` before any transaction can execute:

| Spend Amount | Authorization Mode | Execution Path |
|---|---|---|
| **Tier 1 (<= $50.00)** | `0x01` Autonomous ECDSA Session Key | **Zero human prompt**. UserOp is valid and mined instantly. |
| **Tier 2 ($50.00 - $200.00)** | `0x02` Agent Key + Passkey Quorum | **Escalated**. Agent pauses; owner authorizes via Touch ID / WebAuthn. |
| **Tier 3 (> $200.00)** | Blocked Fail-Closed | **Reverts on-chain**. No human or agent signature can bypass the ceiling. |

---

## Why Haptix Wins Track A (Competitive Edge)

| Evaluation Criteria | Typical AI Agent Submission | Haptix Enclave for Binance Agent OS |
|---|---|---|
| **Real Problem Solved** | Wraps an LLM API with simple chat prompts. | Solves the **#1 blocker to real capital deployment**: autonomous on-chain execution with zero wallet-drain risk. |
| **Binance Integration** | Static mock data or read-only scraper. | **Live Binance Agent OS MCP ingestion** (ETH/USDC ticker, 24h momentum, and top-of-book spreads). |
| **On-Chain Proofs** | Mock scripts or testnet contract with no tx history. | **Live on BNB Smart Chain Testnet**: Real smart account ([`0xE12c6D4a5a40A75885BB4b7503F76C1e41C306C5`](https://testnet.bscscan.com/address/0xE12c6D4a5a40A75885BB4b7503F76C1e41C306C5)), multi-chain co-deployment on Base Sepolia, verified autonomous UserOps, and on-chain AA24 policy rejection proofs. |
| **Hardware Biometrics** | Private keys in plain text `.env` or software wallets. | **Hardware Apple Secure Enclave Passkeys** via native **RIP-7212 precompile (`0x100`)**. |
| **Test Coverage** | 0 to 5 unit tests. | **293 automated tests passing** (243 Foundry Solidity tests + 50 TypeScript SDK tests). |
| **Judge Experience** | CLI scripts with complex setup. | **1-command runtime demo** (`npm run demo:binance`) + **Interactive Web Console** with WebAuthn Touch ID ceremonies. |

---

## Interactive Web Console & Developer UI

Launch the interactive web console and live telemetry dashboard:

```bash
# Launch the interactive web console
npx serve web -l 5199
```
Open **[http://localhost:5199/grant-session](http://localhost:5199/grant-session)** to interactively simulate all 3 tiers and test hardware Touch ID passkey escalation.

---

## License

MIT © 2026 Haptix Core Contributors.
