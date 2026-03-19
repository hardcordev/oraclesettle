import { useState, useEffect, useCallback } from 'react'
import {
  ADDRESSES, FACTORY_ABI, HOOK_ABI, POOL_MANAGER_ABI,
  unichainClient, buildPoolKey, encodePoolId, computeEncodedKey,
  encodeCreate, sendTx, waitForTx, blockscoutTx,
  saveQuestion, loadQuestion, clearQuestion,
  QuestionState, yesProb, fmt6, fmtPrice8,
  CHAIN_IDS,
} from '../constants'

interface MarketState {
  phase:           number  // 0=TRADING, 1=RESOLVED
  yesWon:          boolean
  targetPrice:     bigint
  expiryTimestamp: bigint
  settledPrice:    bigint
  initialized:     boolean
  vault:           `0x${string}`
}

interface Props {
  account:    `0x${string}` | null
  chainId:    number | null
  question:   QuestionState | null
  onQuestion: (q: QuestionState | null) => void
}

export default function MarketPanel({ account, chainId, question, onQuestion }: Props) {
  const [targetUsd, setTargetUsd] = useState('5000')
  const [expiryDate, setExpiryDate] = useState('')
  const [busy, setBusy] = useState(false)
  const [status, setStatus] = useState<string | null>(null)
  const [txHash, setTxHash] = useState<`0x${string}` | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [loadId, setLoadId] = useState('')

  const [marketState, setMarketState] = useState<MarketState | null>(null)
  const [sqrtPriceX96, setSqrtPriceX96] = useState<bigint>(0n)
  const [countdown, setCountdown] = useState('')

  const onUnichain = chainId === CHAIN_IDS.UNICHAIN

  // Default expiry to 24h from now on mount
  useEffect(() => {
    const d = new Date(Date.now() + 86400 * 1000)
    setExpiryDate(d.toISOString().slice(0, 16))
  }, [])

  // Poll market state when question is loaded
  const pollMarket = useCallback(async () => {
    if (!question) return
    try {
      const key = buildPoolKey(question)
      const state = await unichainClient.readContract({
        address:      ADDRESSES.HOOK,
        abi:          HOOK_ABI,
        functionName: 'getMarketState',
        args:         [key as never],
      }) as MarketState
      setMarketState(state)

      // Pool slot0 for implied probability
      const poolId = encodePoolId(question)
      const slot0 = await unichainClient.readContract({
        address:      ADDRESSES.POOL_MANAGER,
        abi:          POOL_MANAGER_ABI,
        functionName: 'getSlot0',
        args:         [poolId],
      }) as unknown as readonly [bigint, number, number, number]
      setSqrtPriceX96(slot0[0])
    } catch { /* pool may not exist yet */ }
  }, [question])

  useEffect(() => {
    pollMarket()
    const iv = setInterval(pollMarket, 8000)
    return () => clearInterval(iv)
  }, [pollMarket])

  // Countdown to expiry
  useEffect(() => {
    if (!marketState) return
    const tick = () => {
      const now = Math.floor(Date.now() / 1000)
      const diff = Number(marketState.expiryTimestamp) - now
      if (diff <= 0) { setCountdown('Expired'); return }
      const h = Math.floor(diff / 3600)
      const m = Math.floor((diff % 3600) / 60)
      const s = diff % 60
      setCountdown(`${h}h ${m}m ${s}s`)
    }
    tick()
    const iv = setInterval(tick, 1000)
    return () => clearInterval(iv)
  }, [marketState])

  async function createQuestion() {
    if (!account || !onUnichain) return
    setError(null); setBusy(true); setStatus('Creating question…')

    try {
      // Convert $USD to Chainlink 8-decimal int256
      const targetPrice = BigInt(Math.round(parseFloat(targetUsd) * 1e8))
      if (targetPrice <= 0n) throw new Error('Invalid target price')

      const expiry = BigInt(Math.floor(new Date(expiryDate).getTime() / 1000))
      if (expiry <= BigInt(Math.floor(Date.now() / 1000))) throw new Error('Expiry must be in the future')

      // Read questionCount before tx so we know the new ID
      const countBefore = await unichainClient.readContract({
        address:      ADDRESSES.FACTORY,
        abi:          FACTORY_ABI,
        functionName: 'questionCount',
        args:         [],
      }) as bigint

      const data = encodeCreate(targetPrice, expiry)
      setStatus('Waiting for wallet…')
      const hash = await sendTx(ADDRESSES.FACTORY, data, account, undefined, 3_000_000)
      setTxHash(hash)
      setStatus('Confirming transaction…')
      await waitForTx(hash)

      // Read question data from factory — retry up to 6x (12s) to allow RPC to catch up
      let qObj = { vault: '0x0000000000000000000000000000000000000000' as `0x${string}`, yes: '0x' as `0x${string}`, no: '0x' as `0x${string}`, poolId: '0x' as `0x${string}` }
      for (let attempt = 0; attempt < 6; attempt++) {
        await new Promise(r => setTimeout(r, 2000))
        const q = await unichainClient.readContract({
          address:      ADDRESSES.FACTORY,
          abi:          FACTORY_ABI,
          functionName: 'questions',
          args:         [countBefore],
        }) as unknown as readonly [`0x${string}`, `0x${string}`, `0x${string}`, `0x${string}`]
        qObj = { vault: q[0], yes: q[1], no: q[2], poolId: q[3] }
        if (qObj.vault !== '0x0000000000000000000000000000000000000000') break
      }

      if (qObj.vault === '0x0000000000000000000000000000000000000000') {
        throw new Error('Transaction confirmed but question not found — factory.create() may have reverted')
      }

      // Sort yes/no for currency0/currency1
      const [c0, c1] = BigInt(qObj.yes) < BigInt(qObj.no)
        ? [qObj.yes, qObj.no] as [`0x${string}`, `0x${string}`]
        : [qObj.no,  qObj.yes] as [`0x${string}`, `0x${string}`]

      const newQ: QuestionState = {
        questionId:  Number(countBefore),
        vault:       qObj.vault,
        yes:         qObj.yes,
        no:          qObj.no,
        poolId:      qObj.poolId,
        currency0:   c0,
        currency1:   c1,
        targetPrice: targetPrice.toString(),
        expiry:      Number(expiry),
      }

      saveQuestion(newQ)
      onQuestion(newQ)
      setStatus('Question created!')
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
      setStatus(null)
    } finally {
      setBusy(false)
    }
  }

  async function loadQuestionById() {
    const id = parseInt(loadId)
    if (isNaN(id)) { setError('Invalid question ID'); return }
    setError(null); setBusy(true)
    try {
      const qRaw = await unichainClient.readContract({
        address:      ADDRESSES.FACTORY,
        abi:          FACTORY_ABI,
        functionName: 'questions',
        args:         [BigInt(id)],
      }) as unknown as readonly [`0x${string}`, `0x${string}`, `0x${string}`, `0x${string}`]
      const q = { vault: qRaw[0], yes: qRaw[1], no: qRaw[2], poolId: qRaw[3] }

      if (q.vault === '0x0000000000000000000000000000000000000000') {
        setError('Question not found'); return
      }

      // Need targetPrice + expiry from MarketState
      const [c0, c1] = BigInt(q.yes) < BigInt(q.no)
        ? [q.yes, q.no] as [`0x${string}`, `0x${string}`]
        : [q.no,  q.yes] as [`0x${string}`, `0x${string}`]

      // Build a partial question to fetch market state
      const partialQ: QuestionState = {
        questionId: id, vault: q.vault, yes: q.yes, no: q.no,
        poolId: q.poolId, currency0: c0, currency1: c1,
        targetPrice: '0', expiry: 0,
      }
      const key = buildPoolKey(partialQ)
      const ms = await unichainClient.readContract({
        address:      ADDRESSES.HOOK,
        abi:          HOOK_ABI,
        functionName: 'getMarketState',
        args:         [key as never],
      }) as MarketState

      const loaded: QuestionState = {
        ...partialQ,
        targetPrice: ms.targetPrice.toString(),
        expiry:      Number(ms.expiryTimestamp),
      }
      saveQuestion(loaded)
      onQuestion(loaded)
      setError(null)
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
    }
  }

  // Determine YES currency for probability calculation
  const yesCurrency = question
    ? (question.yes.toLowerCase() === question.currency0.toLowerCase() ? 'currency0' : 'currency1')
    : 'currency0'

  const prob = yesProb(sqrtPriceX96, yesCurrency as 'currency0' | 'currency1')
  const probNo = 100 - prob

  return (
    <div className="p-4 space-y-4 max-w-2xl mx-auto">

      {/* ── Active Question ──────────────────────────── */}
      {question && (
        <div className="bg-os-card border border-os-border rounded-xl p-4 space-y-4">
          <div className="flex items-center justify-between">
            <div className="text-xs font-semibold text-white">Question #{question.questionId}</div>
            <div className="flex items-center gap-2">
              {marketState && (
                <span className={[
                  'px-2 py-0.5 text-[10px] font-mono rounded-full border',
                  marketState.phase === 0
                    ? 'bg-os-yes-dim text-os-yes border-os-yes/30'
                    : 'bg-os-blue-dim text-os-blue border-os-blue/30',
                ].join(' ')}>
                  {marketState.phase === 0 ? 'TRADING' : 'RESOLVED'}
                </span>
              )}
              <button
                onClick={() => { clearQuestion(); onQuestion(null) }}
                className="text-[10px] text-os-text hover:text-os-no transition-colors"
              >
                Clear
              </button>
            </div>
          </div>

          {/* Probability gauge */}
          {sqrtPriceX96 > 0n && (
            <div className="space-y-2">
              <div className="text-[10px] font-mono text-os-text uppercase tracking-wider">Implied Probability</div>
              <div className="flex h-6 rounded-lg overflow-hidden border border-os-border">
                <div
                  className="flex items-center justify-center text-[10px] font-bold text-white bg-os-yes transition-all duration-500"
                  style={{ width: `${Math.max(4, prob)}%` }}
                >
                  {prob.toFixed(1)}%
                </div>
                <div
                  className="flex items-center justify-center text-[10px] font-bold text-white bg-os-no transition-all duration-500"
                  style={{ width: `${Math.max(4, probNo)}%` }}
                >
                  {probNo.toFixed(1)}%
                </div>
              </div>
              <div className="flex justify-between text-[10px] font-mono text-os-text">
                <span className="text-os-yes">YES wins</span>
                <span className="text-os-no">NO wins</span>
              </div>
            </div>
          )}

          {/* Market details grid */}
          {marketState && (
            <div className="grid grid-cols-2 gap-2 text-[11px]">
              <Detail label="Target Price" value={fmtPrice8(marketState.targetPrice)} />
              <Detail
                label="Expiry"
                value={countdown || new Date(Number(marketState.expiryTimestamp) * 1000).toLocaleString()}
              />
              {marketState.phase === 1 && (
                <>
                  <Detail label="Winner" value={marketState.yesWon ? '✅ YES' : '❌ NO'} />
                  <Detail label="Settled At" value={fmtPrice8(marketState.settledPrice)} />
                </>
              )}
              <Detail label="Vault" value={question.vault.slice(0, 10) + '…'} mono />
              <Detail label="Pool ID"  value={question.poolId.slice(0, 10) + '…'} mono />
            </div>
          )}

          {/* Token addresses */}
          <div className="space-y-1">
            <div className="text-[10px] font-mono text-os-text uppercase tracking-wider">Tokens</div>
            <div className="grid grid-cols-2 gap-2">
              <div className="bg-os-yes-dim border border-os-yes/20 rounded-lg p-2">
                <div className="text-[10px] text-os-yes font-semibold mb-1">YES Token</div>
                <div className="text-[10px] font-mono text-os-text break-all">{question.yes}</div>
              </div>
              <div className="bg-os-no-dim border border-os-no/20 rounded-lg p-2">
                <div className="text-[10px] text-os-no font-semibold mb-1">NO Token</div>
                <div className="text-[10px] font-mono text-os-text break-all">{question.no}</div>
              </div>
            </div>
          </div>

          {/* ENCODED_KEY for RSC deployment */}
          <Phase3Command question={question} />
        </div>
      )}

      {/* ── Create New Question ──────────────────────── */}
      {!question && (
        <div className="bg-os-card border border-os-border rounded-xl p-4 space-y-4">
          <div className="text-sm font-semibold text-white">Create Prediction Question</div>
          <div className="text-xs text-os-text">
            Deploys YES + NO tokens, CollateralVault, and initialises the Uniswap v4 YES/NO pool.
            Then deploy the Reactive RSC to link Chainlink settlement.
          </div>

          <div className="grid grid-cols-2 gap-3">
            <div>
              <label className="block text-[11px] font-mono text-os-text mb-1">
                Target ETH/USD Price
              </label>
              <div className="flex items-center bg-os-bg border border-os-border rounded-lg overflow-hidden">
                <span className="px-2 text-os-text text-sm">$</span>
                <input
                  type="number"
                  value={targetUsd}
                  onChange={e => setTargetUsd(e.target.value)}
                  placeholder="5000"
                  className="flex-1 bg-transparent px-2 py-2 text-sm text-white outline-none"
                />
              </div>
              <div className="text-[9px] font-mono text-os-text mt-0.5">
                = {targetUsd ? BigInt(Math.round(parseFloat(targetUsd || '0') * 1e8)).toString() : '0'} (8-dec)
              </div>
            </div>

            <div>
              <label className="block text-[11px] font-mono text-os-text mb-1">
                Expiry Date/Time (local)
              </label>
              <input
                type="datetime-local"
                value={expiryDate}
                onChange={e => setExpiryDate(e.target.value)}
                className="w-full bg-os-bg border border-os-border rounded-lg px-3 py-2 text-sm text-white outline-none"
              />
              {expiryDate && (
                <div className="text-[9px] font-mono text-os-text mt-0.5">
                  unix: {Math.floor(new Date(expiryDate).getTime() / 1000)}
                </div>
              )}
            </div>
          </div>

          {!account && (
            <div className="text-[11px] text-yellow-400 font-mono">Connect wallet to create a question.</div>
          )}
          {account && !onUnichain && (
            <div className="text-[11px] text-yellow-400 font-mono">Switch to Unichain Sepolia to continue.</div>
          )}

          {status && (
            <div className="flex items-center gap-2 text-[11px] font-mono text-os-blue">
              <span className="w-3 h-3 rounded-full border-2 border-os-blue border-t-transparent animate-spin inline-block" />
              {status}
              {txHash && (
                <a href={blockscoutTx(txHash)} target="_blank" rel="noopener noreferrer" className="underline">
                  view tx
                </a>
              )}
            </div>
          )}
          {error && <div className="text-[11px] font-mono text-os-no">{error}</div>}

          <button
            onClick={createQuestion}
            disabled={busy || !account || !onUnichain}
            className="w-full py-2.5 text-sm font-semibold bg-os-blue hover:bg-blue-500 disabled:opacity-40 disabled:cursor-not-allowed text-white rounded-lg transition-colors"
          >
            {busy ? 'Creating…' : 'Create Question'}
          </button>
        </div>
      )}

      {/* ── Load Existing Question ───────────────────── */}
      <div className="bg-os-card border border-os-border rounded-xl p-4 space-y-3">
        <div className="text-xs font-semibold text-white">Load Existing Question</div>
        <div className="flex gap-2">
          <input
            type="number"
            value={loadId}
            onChange={e => setLoadId(e.target.value)}
            placeholder="Question ID (e.g. 0)"
            className="flex-1 bg-os-bg border border-os-border rounded-lg px-3 py-2 text-sm text-white outline-none"
          />
          <button
            onClick={loadQuestionById}
            disabled={busy}
            className="px-4 py-2 text-xs font-semibold bg-os-card border border-os-border hover:border-os-blue text-white rounded-lg transition-colors disabled:opacity-40"
          >
            Load
          </button>
        </div>
        {error && !busy && <div className="text-[11px] font-mono text-os-no">{error}</div>}
      </div>

      {/* ── Faucet Info ──────────────────────────────── */}
      <div className="bg-os-blue-dim border border-os-blue/20 rounded-xl p-3">
        <div className="text-[11px] font-semibold text-os-blue mb-1">Need USDC on Unichain Sepolia?</div>
        <div className="text-[10px] text-os-text">
          Bridge from Ethereum Sepolia or get test USDC at faucet.circle.com.
          USDC address: <span className="font-mono text-white">{ADDRESSES.USDC}</span>
        </div>
      </div>
    </div>
  )
}

function Phase3Command({ question }: { question: QuestionState }) {
  const [copied, setCopied] = useState(false)
  const encodedKey = computeEncodedKey(question)

  const forgeCmd = [
    `forge create src/OracleSettleReactive.sol:OracleSettleReactive \\`,
    `  --rpc-url $REACTIVE_LASNA_RPC \\`,
    `  --private-key $REACTIVE_PRIVATE_KEY \\`,
    `  --value 0.5ether \\`,
    `  --constructor-args \\`,
    `  0x694AA1769357215DE4FAC081bf1f309aDC325306 \\`,
    `  ${ADDRESSES.CALLBACK} \\`,
    `  ${encodedKey} \\`,
    `  ${question.targetPrice} \\`,
    `  ${question.expiry} \\`,
    `  11155111 \\`,
    `  1301`,
  ].join('\n')

  function copy() {
    navigator.clipboard.writeText(forgeCmd).then(() => {
      setCopied(true)
      setTimeout(() => setCopied(false), 2000)
    })
  }

  return (
    <div className="bg-os-bg border border-os-border rounded-lg p-3 space-y-2">
      <div className="flex items-center justify-between">
        <div className="text-[10px] font-mono text-os-blue uppercase tracking-wider">
          Phase 3 — Deploy RSC to Reactive Lasna (CLI, once per question)
        </div>
        <button
          onClick={copy}
          className="text-[10px] px-2 py-0.5 border border-os-border rounded hover:border-os-blue text-os-text hover:text-white transition-colors"
        >
          {copied ? '✓ Copied' : 'Copy'}
        </button>
      </div>
      <pre className="text-[9px] font-mono text-white/80 whitespace-pre-wrap break-all leading-relaxed overflow-x-auto">
        {forgeCmd}
      </pre>
      <div className="text-[9px] text-os-text space-y-0.5">
        <div>• <strong className="text-white">REACTIVE_LASNA_RPC</strong> = https://lasna-rpc.rnk.dev/</div>
        <div>• Needs lREACT: send 0.1 ETH to faucet <span className="font-mono text-white">0x9b9BB25f1A81078C544C829c5EB7822d747Cf434</span> on Ethereum Sepolia</div>
        <div>• Each question needs its own RSC — the RSC is hardwired to this pool key, target price, and expiry</div>
      </div>
    </div>
  )
}

function Detail({ label, value, mono }: { label: string; value: string; mono?: boolean }) {
  return (
    <div className="bg-os-bg border border-os-border rounded-lg p-2">
      <div className="text-[9px] font-mono text-os-text uppercase tracking-wider mb-0.5">{label}</div>
      <div className={['text-xs text-white font-semibold', mono ? 'font-mono' : ''].join(' ')}>{value}</div>
    </div>
  )
}
