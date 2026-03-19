# OracleSettle: Cross-Chain Prediction Market Settlement Hook

**A Uniswap v4 hook that turns any price feed into a binary prediction market with guaranteed 1:1 USDC settlement. A Reactive Network RSC monitors Chainlink on Ethereum and triggers irreversible pool settlement on Unichain — no off-chain keepers, no trusted operators, no slippage on redemption.**

## Problem

On-chain prediction markets face three compounding problems:

1. **Cross-chain oracle gap.** A Uniswap v4 hook on Unichain cannot read Chainlink's ETH/USD feed on Ethereum. Without a trustless bridge for oracle data, binary settlement is structurally impossible in a hook.
2. **Slippage on redemption.** Most AMM-based prediction markets redeem winning positions through a swap, exposing winners to AMM price impact at the exact moment everyone is trying to exit simultaneously.
3. **No redemption path for one side.** When a prediction market uses a YES/USDC pool, the NO side has no token and no claim — holders simply kept their USDC. There is no symmetric payout.

## Solution

OracleSettle solves all three:

1. **Reactive Network** bridges the oracle — a Reactive Smart Contract (RSC) subscribes to Chainlink `AnswerUpdated` on Ethereum and delivers a settlement callback to Unichain. This is structurally required, not optional.
2. **CollateralVault** holds all USDC collateral. After settlement, `vault.redeem(amount)` burns the winning token and pays exactly **1 USDC per token** — no AMM, no slippage, guaranteed.
3. **YES and NO are both real ERC20 tokens.** Both sides have a symmetric payout. The winning side redeems 1:1; the losing side's tokens are worthless.

## How It Works

### The Question

Every prediction market question is defined by three parameters set at deployment:

| Parameter | Example | Meaning |
|-----------|---------|---------|
| `chainlinkFeed` | `0x694AA1...` (ETH/USD Sepolia) | What price to monitor |
| `targetPrice` | `500000000000` (5000e8) | The threshold — Chainlink 8-decimal format |
| `expiryTimestamp` | `1742358400` | When to evaluate the price |

The yes/no resolution is a single comparison: `yesWon = (currentPrice >= targetPrice)`. Everything else flows from this.

### Market Lifecycle

| Phase | Trigger | What Users Can Do |
|-------|---------|-------------------|
| **TRADING** | `factory.create()` called | `vault.mint()` to get YES+NO; swap YES/NO on pool; `vault.burn()` to exit symmetrically |
| **RESOLVED** | Oracle triggers settlement | ALL pool swaps blocked; `vault.redeem()` to claim 1 USDC per winning token |

The TRADING → RESOLVED transition is **one-way and irreversible**. A second settlement call reverts `MarketAlreadySettled`.

### TRADING Phase

- Call `vault.mint(amount)` → deposit `amount` USDC, receive `amount` YES + `amount` NO tokens (1:1)
- Trade YES/NO on the Uniswap v4 pool — the YES/NO price ratio reflects the market's collective probability estimate
- LPs seed and maintain liquidity; earn 1% swap fees on all volume
- Change your mind? Call `vault.burn(amount)` → return equal YES+NO, recover USDC (pre-settlement only)

### RESOLVED Phase

When Chainlink confirms the expiry price on Ethereum, the RSC triggers settlement across chains:

- Hook sets `market.phase = RESOLVED`; calls `vault.settle(yesWon)`
- **All pool swaps are blocked** — both directions, regardless of outcome
- **YES wins:** YES holders call `vault.redeem(amount)` → vault burns YES, transfers exactly 1 USDC per token
- **NO wins:** NO holders call `vault.redeem(amount)` → vault burns NO, transfers exactly 1 USDC per token
- Losing token holders have no redemption path

## Architecture

```
ETHEREUM                      REACTIVE NETWORK                      UNICHAIN
========                      ================                      ========

Chainlink ETH/USD             OracleSettleReactive.sol
  event AnswerUpdated(  ---->  Subscription: chainlinkFeed, AnswerUpdated
    int256 current,             1. Filter: topic_0, feed address, chain_id
    uint256 roundId,            2. Guard:  if settled → return
    uint256 updatedAt           3. Check:  if updatedAt < expiry → return
  )                             4. Compute: yesWon = (current >= targetPrice)
                                5. settled = true
                                6. emit SettlementTriggered(yesWon, price)
                                7. emit Callback(
                                     chain_id=1301,
                                     contract=callbackContract,
                                     payload=resolveMarket(encodedKey, yesWon, price)
                                   )
                                              |
                                              v
                                   OracleSettleCallback.sol  ------>  OracleSettleHook.sol
                                   - rvmIdOnly guard                  - market.phase = RESOLVED
                                   - decode PoolKey                   - market.yesWon = yesWon
                                   - call hook.settle()               - market.settledPrice = price
                                   - emit MarketSettledRelayed        - vault.settle(yesWon)
                                                                              |
                                                                              v
                                                                      CollateralVault.sol
                                                                      - settled = true
                                                                      - yesWon = yesWon
                                                                      - redeem() now enabled
                                                                      - burn() now blocked

                                                                      beforeSwap on all future
                                                                      pool swaps → REVERT
```

## Contracts

| Contract | Network | Purpose |
|----------|---------|---------|
| `OracleSettleHook.sol` | Unichain | Uniswap v4 hook — lifecycle state machine, `beforeSwap` enforcement |
| `OracleSettleCallback.sol` | Unichain | Reactive Network callback receiver |
| `OracleSettleReactive.sol` | Reactive Network | Monitors Chainlink; computes outcome; relays settlement |
| `CollateralVault.sol` | Unichain | Holds USDC; mints YES+NO pairs 1:1; guarantees 1 USDC redemption per winning token |
| `OutcomeToken.sol` | Unichain | ERC20 for YES and NO; vault-only mint/burn |
| `QuestionFactory.sol` | Unichain | Deploys YES + NO + vault + pool per question in one transaction |

### OracleSettleHook

Uniswap v4 hook enforcing the market lifecycle at the protocol level.

**Hook Permissions:** `beforeInitialize`, `beforeSwap`

| Hook | Behavior |
|------|----------|
| `beforeInitialize` | No-op — pool can initialize; market is registered via `initMarket` separately |
| `beforeSwap` | TRADING: allow all. RESOLVED: revert `SwapBlockedAfterSettlement` on every swap direction |

**Key Functions:**

| Function | Access | Description |
|----------|--------|-------------|
| `initMarket(key, targetPrice, expiry, vault)` | Owner or Factory | Register prediction question for a pool; stores vault address in MarketState |
| `settle(key, yesWon, settledPrice)` | Callback only | Transition phase to RESOLVED; propagate to vault via `vault.settle(yesWon)` |
| `setCallbackContract(callback)` | Owner | Wire callback address — one-time, reverts `CallbackAlreadySet` if already set |
| `setFactory(factory)` | Owner | Authorize QuestionFactory to call `initMarket` |
| `getMarketState(key)` | View | Returns full 7-field MarketState (phase, yesWon, targetPrice, expiry, settledPrice, initialized, vault) |

**MarketState struct:**
```solidity
struct MarketState {
    Phase   phase;            // TRADING or RESOLVED
    bool    yesWon;           // valid only when RESOLVED
    int256  targetPrice;      // e.g. 5000e8 for $5,000 (Chainlink 8-decimal)
    uint256 expiryTimestamp;  // unix timestamp
    int256  settledPrice;     // actual Chainlink price at settlement
    bool    initialized;      // true after initMarket()
    address vault;            // CollateralVault; address(0) = no vault attached
}
```

### CollateralVault

Holds all USDC backing the prediction market. Mints and burns outcome token pairs. Guarantees 1:1 USDC redemption for winners.

| Function | Access | Description |
|----------|--------|-------------|
| `mint(amount)` | Anyone | Transfer `amount` USDC in; mint `amount` YES + `amount` NO to caller |
| `burn(amount)` | Anyone | Return `amount` YES + `amount` NO; receive `amount` USDC back. Reverts `AlreadySettled` post-settlement |
| `settle(yesWon)` | Hook only | Lock vault for redemption; record which side won. Irreversible. |
| `redeem(amount)` | Anyone | Burn winning token from caller (`yesWon` ? YES : NO); transfer `amount` USDC. Reverts `NotSettled` pre-settlement |

Key design: `burn()` requires equal YES and NO balances — it is a symmetric exit. Users who have gone directional (sold one token on the pool) must trade back to parity before burning, or simply wait for settlement.

### QuestionFactory

Deploys and wires all contracts for a new question in one transaction. Calls `hook.initMarket()` automatically.

**`create(targetPrice, expiry)` flow:**
1. Deploy YES `OutcomeToken` and NO `OutcomeToken` (vault placeholder = address(0))
2. Deploy `CollateralVault(usdc, yes, no, hook)`
3. Call `yes.setVault(vault)` and `no.setVault(vault)` — vault is now the sole minter
4. Sort token addresses: lower address → currency0
5. Build `PoolKey` (fee=10000, tickSpacing=200)
6. Call `poolManager.initialize(poolKey, SQRT_PRICE_1_1)` — pool starts at 1:1 (probability = 0.5)
7. Call `hook.initMarket(poolKey, targetPrice, expiry, vault)`
8. Return: `questionId`, `vault address`, `abi.encode(poolKey)` (the `ENCODED_KEY` for Reactive deployment)

### OracleSettleReactive

Deployed on Reactive Network (Lasna). Subscribes to Chainlink `AnswerUpdated` on Ethereum.

**Settlement logic inside `react(log)`:**
```
1. Filter: topic_0 == ANSWER_UPDATED, contract == chainlinkFeed, chain_id == ORIGIN_CHAIN_ID
2. Guard:  if settled → return (prevents double-settlement)
3. Decode: updatedAt = abi.decode(log.data, (uint256))
4. Check:  if updatedAt < expiryTimestamp → return (not yet expired)
5. Compute: current = int256(log.topic_1); yesWon = (current >= targetPrice)
6. settled = true
7. emit SettlementTriggered(yesWon, current, updatedAt)
8. emit Callback(DEST_CHAIN_ID, callbackContract, 300_000 gas, payload)
```

The `encodedKey` (ABI-encoded `PoolKey`) travels from Unichain → Reactive (at deploy time) → back to Unichain inside the callback payload, where `OracleSettleCallback` decodes it to locate the pool.

### OracleSettleCallback

Minimal relay on Unichain. Receives Reactive Network callbacks and forwards to hook.

- `resolveMarket(_rvm_id, encodedKey, yesWon, settledPrice)` — `rvmIdOnly(_rvm_id)` verifies the Reactive VM ID to reject unauthorized callers
- Decodes `PoolKey key = abi.decode(encodedKey, (PoolKey))`
- Calls `hook.settle(key, yesWon, settledPrice)`
- Emits `MarketSettledRelayed(yesWon, settledPrice)`

### OutcomeToken

Solmate ERC20 with vault-gated mint/burn. Deployed twice per question (YES and NO).

- `setVault(address)` — callable once by anyone; reverts `VaultAlreadySet` if already set
- `mint(to, amount)` — `onlyVault`
- `burn(from, amount)` — `onlyVault`

## File Structure

```
oraclesettle/
├── src/
│   ├── OracleSettleHook.sol       # Uniswap v4 hook (beforeInitialize + beforeSwap)
│   ├── OracleSettleCallback.sol   # Reactive Network relay (rvmIdOnly)
│   ├── OracleSettleReactive.sol   # RSC: Chainlink subscription, settlement logic
│   ├── CollateralVault.sol        # USDC vault: mint/burn/settle/redeem
│   ├── OutcomeToken.sol           # ERC20 outcome token (vault-only mint/burn)
│   └── QuestionFactory.sol        # Deploys YES+NO+vault+pool per question
├── test/
│   ├── OutcomeToken.t.sol         # 28 tests (constructor, setVault, mint, burn, ERC20, fuzz)
│   ├── CollateralVault.t.sol      # 36 tests (mint, burn, settle, redeem, fuzz, failure paths)
│   ├── QuestionFactory.t.sol      # 23 tests (deployment, pool key, hook registration, fuzz)
│   ├── OracleSettleHook.t.sol     # 51 tests (initMarket, settle, beforeSwap, multi-market, fuzz)
│   ├── OracleSettleUserJourneys.t.sol  # 16 end-to-end lifecycle tests
│   └── OracleSettleReactive.t.sol # 24 tests (filtering, timing, outcomes, encoding, fuzz)
├── script/
│   ├── DeployHook.s.sol           # Deploy hook + callback + factory; wire together
│   ├── CreateQuestion.s.sol       # Call factory.create(); print ENCODED_KEY
│   └── DeployReactive.s.sol       # Deploy RSC on Reactive Lasna
├── foundry.toml
├── remappings.txt
└── lib/
    ├── forge-std/
    ├── v4-periphery/              # includes v4-core, solmate, permit2
    └── reactive-lib/              # AbstractReactive, AbstractCallback
```

## Getting Started

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)

### Build

```bash
cd oraclesettle
forge build
```

### Test

```bash
# All 178 tests
forge test --summary

# End-to-end user journeys only
forge test --match-path test/OracleSettleUserJourneys.t.sol -vv

# Specific journey
forge test -vvv --match-test test_journey_yesWin_fullLifecycle

# Gas report
forge test --gas-report
```

### Deploy

**Step 1 — Unichain Sepolia (Hook + Callback + Factory):**
```bash
PRIVATE_KEY=<key> \
forge script script/DeployHook.s.sol \
  --rpc-url https://sepolia.unichain.org --broadcast
# Save: HOOK_ADDRESS, CALLBACK_ADDRESS, FACTORY_ADDRESS
```

**Step 2 — Unichain Sepolia (Create Question):**
```bash
FACTORY_ADDRESS=<from step 1> \
TARGET_PRICE=500000000000 \
EXPIRY_TIMESTAMP=<unix> \
forge script script/CreateQuestion.s.sol \
  --rpc-url https://sepolia.unichain.org --broadcast
# Save: ENCODED_KEY, vault address, YES/NO token addresses
```

**Step 3 — Reactive Lasna (RSC):**
```bash
forge create src/OracleSettleReactive.sol:OracleSettleReactive \
  --rpc-url https://lasna-rpc.rnk.dev/ \
  --private-key <reactive-key> \
  --value 0.1ether \
  --constructor-args \
    <callback-address> \
    <encoded-key-from-step-2> \
    500000000000 \
    <expiry-timestamp> \
    0x694AA1769357215DE4FAC081bf1f309aDC325306 \
    11155111 \
    1301 \
  --broadcast
```

## Tests

**178 tests across six files — all passing.**

### OracleSettleUserJourneys.t.sol (16 tests)

End-to-end lifecycle simulations proving the full architecture works as an integrated system:

| Journey | What It Proves |
|---------|----------------|
| YES win full lifecycle | Alice mints → holds YES → oracle resolves YES → `vault.redeem()` returns 1 USDC per YES |
| NO win full lifecycle | Bob mints → holds NO → oracle resolves NO → `vault.redeem()` returns 1 USDC per NO |
| Price discovery | Multiple traders swap YES/NO; market stays TRADING; all swaps succeed |
| LP exits after YES win | LP adds liquidity, fees accumulate, YES settles, LP removes successfully |
| LP exits after NO win | Same but NO outcome; LP removes even when all swaps are blocked |
| Cross-chain settlement | Full path: RSC react() → Callback event → resolveMarket() → hook.settle() → vault.settle() |
| Mint → burn → settle → redeem | Alice mints, burns half pre-settlement, redeems winning tokens post-settlement |
| Both swap directions blocked | After YES settlement, both zeroForOne and oneForZero revert |
| vault.burn blocked after settle | `vault.burn()` reverts `AlreadySettled` after settlement |
| Two simultaneous questions | Question A settles YES, Question B settles NO — fully independent state |
| Wrong RVM ID reverts | Passing `address(0xBAD)` as `_rvm_id` reverts "Authorized RVM ID only" |
| Correct RVM settles | Correct `_rvm_id` settles hook and vault atomically |
| Fuzz: any price | Any price → hook resolves correctly; `yesWon == (price >= TARGET_PRICE)` |
| Fuzz: LP always exits | LP removal never blocked regardless of YES or NO outcome |
| Fuzz: swap in trading phase | Any bounded non-zero swap amount succeeds in TRADING |
| Fuzz: redeem amount | Any bounded redeem amount → correct USDC returned |

### OracleSettleHookTest.t.sol (51 tests)
- `initMarket` with vault address — all 7 MarketState fields set correctly
- Factory authorization — `setFactory`, factory can call `initMarket`, non-factory reverts
- `settle()` propagates to CollateralVault — vault.settled and vault.yesWon set correctly
- `settle()` with no vault (address(0)) — hook settles cleanly without vault call
- `_beforeSwap` blocks ALL directions when RESOLVED (both zeroForOne and oneForZero)
- `setCallbackContract` — one-time set, ZeroAddress and CallbackAlreadySet guards
- Multiple independent markets — settling pool2 does not affect pool1
- `getMarketState` — returns all 7 fields including vault address
- Fuzz: any targetPrice, any settledPrice, any swap amount in TRADING

### CollateralVaultTest.t.sol (36 tests)
- `mint`: USDC deducted, equal YES+NO minted; ZeroAmount guard; insufficient balance/allowance
- `burn`: USDC returned, YES+NO burned; AlreadySettled guard; ZeroAmount guard
- `settle`: onlyHook enforcement; AlreadySettled guard; yesWon/settled flags set; event emitted
- `redeem`: YES wins → YES burned; NO wins → NO burned; NotSettled guard; wrong-side reverts
- Fuzz: mint/burn roundtrip recovers all USDC; redeem any amount with correct USDC return

### QuestionFactoryTest.t.sol (23 tests)
- YES + NO + vault all deployed with correct constructor arguments
- Vault is wired as the sole minter on both tokens after `create()`
- Pool initialized at 1:1 sqrtPrice; currencies correctly sorted
- `hook.initMarket` called with correct targetPrice, expiry, and vault address
- Two questions deploy independent pools and vaults
- `questionCount` increments; `questions[id]` mapping populated
- Fuzz: any targetPrice, any expiry, N questions created sequentially

### OutcomeTokenTest.t.sol (28 tests)
- Constructor, name/symbol/decimals, initial supply
- `setVault`: callable once; VaultAlreadySet and ZeroAddress guards
- `mint` and `burn`: vault-only; OnlyVault revert from non-vault callers
- Full ERC20 standard: transfer, approve, transferFrom, insufficient balance/allowance
- Fuzz: mint/burn any amount; transfer any amount

### OracleSettleReactiveTest.t.sol (24 tests)
- Filtering: wrong topic, wrong feed address, wrong chain — all ignored
- Expiry boundary: `updatedAt < expiry` ignored; `>= expiry` settles (exact boundary tested)
- Outcome: price above/below/equal to target → correct yesWon
- Double-settlement prevention: second react call after settled=true is a no-op
- Callback encoding: correct selector, correct chain_id (1301), settledPrice in payload
- `encodedKey` preserved verbatim in callback payload
- Fuzz: any price vs target; any updatedAt vs expiry; negative prices via two's complement

## Partner Integrations

### Reactive Network
- **`src/OracleSettleReactive.sol`** — RSC deployed on Reactive Lasna; single subscription to Chainlink `AnswerUpdated` on Ethereum. This is architecturally required — Unichain hooks cannot read Ethereum state. `react()` is the only path through which settlement can be triggered.
- **`src/OracleSettleCallback.sol`** — deployed on Unichain; receives the cross-chain callback via `rvmIdOnly` modifier. Decodes the ABI-encoded `PoolKey` and calls `hook.settle()`.
- Enables fully trustless settlement with zero off-chain infrastructure.

### Uniswap v4
- **`src/OracleSettleHook.sol`** — deployed on Unichain; uses `BEFORE_INITIALIZE_FLAG | BEFORE_SWAP_FLAG`. `beforeSwap` enforces the TRADING/RESOLVED state machine. Single hook contract supports unlimited simultaneous prediction markets — each `PoolKey` maps to independent `MarketState`.
- **`src/QuestionFactory.sol`** — calls `IPoolManager.initialize()` to create the YES/NO pool at 1:1 starting price.

### Chainlink
- **`src/OracleSettleReactive.sol`** — subscribes to `AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 updatedAt)` at the specified Chainlink feed address on Ethereum. The indexed `current` price (topic_1) and non-indexed `updatedAt` timestamp (log.data) are the two values used for settlement. Default feed: `0x694AA1769357215DE4FAC081bf1f309aDC325306` (ETH/USD Sepolia).

### Unichain
- **`src/OracleSettleHook.sol`** and **`src/OracleSettleCallback.sol`** — deployed on Unichain Sepolia. Unichain's fast finality makes it ideal for time-sensitive settlement: once the Reactive callback lands, the pool transitions atomically.
- Callback proxy address: `0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4`

## Deployed Contracts (Testnet)

| Contract | Network | Address |
|----------|---------|---------|
| **OracleSettleHook** | Unichain Sepolia | `0x51C69Fcca69484F3598DFA0DA1A92c57104eE080` |
| **OracleSettleCallback** | Unichain Sepolia | `0x7dB257225aBC3B4e31f4d97b97e1c60BEec3549e` |
| **QuestionFactory** | Unichain Sepolia | `0x99C0756b7fda5a49bd8368EBc3d37e1B3Ee8498B` |
| **CollateralVault** (Q#0) | Unichain Sepolia | `0x69Fa84d205bb68f2e8CC95d70A778bC02aF892Ed` |
| USDC (Unichain Sepolia) | Unichain Sepolia | `0x31d0220469e10c4E71834a79b1f276d740d3768F` |
| PoolManager | Unichain Sepolia | `0x00B036B58a818B1BC34d502D3fE730Db729e62AC` |
| Callback Proxy | Unichain Sepolia | `0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4` |
| Chainlink ETH/USD | Ethereum Sepolia | `0x694AA1769357215DE4FAC081bf1f309aDC325306` |

## License

MIT
