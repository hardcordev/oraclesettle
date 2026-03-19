import { useState, useEffect, useCallback } from 'react'
import {
  ADDRESSES, ERC20_ABI, PERMIT2_ABI, POOL_MANAGER_ABI,
  unichainClient, buildPoolKey, encodePoolId,
  encodeApprove, encodePermit2Approve, encodeV4Swap,
  sendTx, waitForTx, blockscoutTx,
  QuestionState, fmt6, yesProb, parseUnits, maxUint256, CHAIN_IDS,
} from '../constants'

interface Props {
  account:  `0x${string}` | null
  chainId:  number | null
  question: QuestionState
}

interface TradeBalances {
  yes:             bigint
  no:              bigint
  yesAllowPermit2: bigint
  noAllowPermit2:  bigint
  yesPermit2Allow: bigint  // permit2.allowance for universal router
  noPermit2Allow:  bigint
  sqrtPriceX96:    bigint
}

export default function TradePanel({ account, chainId, question }: Props) {
  const [direction, setDirection] = useState<'yes-to-no' | 'no-to-yes'>('yes-to-no')
  const [amount, setAmount]       = useState('50')
  const [balances, setBalances]   = useState<TradeBalances | null>(null)
  const [busy, setBusy]           = useState(false)
  const [status, setStatus]       = useState<string | null>(null)
  const [txHash, setTxHash]       = useState<`0x${string}` | null>(null)
  const [error, setError]         = useState<string | null>(null)

  const onUnichain = chainId === CHAIN_IDS.UNICHAIN

  const fetchBalances = useCallback(async () => {
    if (!account) return
    try {
      const [yes, no, yesAllowPermit2, noAllowPermit2, slot0] = await Promise.all([
        unichainClient.readContract({ address: question.yes, abi: ERC20_ABI, functionName: 'balanceOf', args: [account] }) as Promise<bigint>,
        unichainClient.readContract({ address: question.no,  abi: ERC20_ABI, functionName: 'balanceOf', args: [account] }) as Promise<bigint>,
        unichainClient.readContract({ address: question.yes, abi: ERC20_ABI, functionName: 'allowance', args: [account, ADDRESSES.PERMIT2] }) as Promise<bigint>,
        unichainClient.readContract({ address: question.no,  abi: ERC20_ABI, functionName: 'allowance', args: [account, ADDRESSES.PERMIT2] }) as Promise<bigint>,
        unichainClient.readContract({
          address:      ADDRESSES.POOL_MANAGER,
          abi:          POOL_MANAGER_ABI,
          functionName: 'getSlot0',
          args:         [encodePoolId(question)],
        }) as unknown as Promise<readonly [bigint, number, number, number]>,
      ])

      // Permit2 allowance for universal router
      const [yP, nP] = await Promise.all([
        unichainClient.readContract({
          address: ADDRESSES.PERMIT2, abi: PERMIT2_ABI, functionName: 'allowance',
          args: [account, question.yes, ADDRESSES.UNIVERSAL_ROUTER],
        }) as unknown as Promise<readonly [bigint, number, number]>,
        unichainClient.readContract({
          address: ADDRESSES.PERMIT2, abi: PERMIT2_ABI, functionName: 'allowance',
          args: [account, question.no, ADDRESSES.UNIVERSAL_ROUTER],
        }) as unknown as Promise<readonly [bigint, number, number]>,
      ])

      setBalances({
        yes, no, yesAllowPermit2, noAllowPermit2,
        yesPermit2Allow: yP[0],
        noPermit2Allow:  nP[0],
        sqrtPriceX96:    slot0[0],
      })
    } catch { /* ignore */ }
  }, [account, question])

  useEffect(() => {
    fetchBalances()
    const iv = setInterval(fetchBalances, 8000)
    return () => clearInterval(iv)
  }, [fetchBalances])

  const amountBig = (() => {
    try { return parseUnits(amount || '0', 6) } catch { return 0n }
  })()

  // Token being sold in this direction
  const sellToken    = direction === 'yes-to-no' ? question.yes : question.no
  const sellSymbol   = direction === 'yes-to-no' ? 'YES' : 'NO'
  const buySymbol    = direction === 'yes-to-no' ? 'NO'  : 'YES'

  const needsErc20Approve = balances !== null && (
    direction === 'yes-to-no'
      ? balances.yesAllowPermit2 < amountBig
      : balances.noAllowPermit2 < amountBig
  )
  const needsPermit2Approve = balances !== null && (
    direction === 'yes-to-no'
      ? balances.yesPermit2Allow < amountBig
      : balances.noPermit2Allow < amountBig
  )

  // zeroForOne: are we selling currency0?
  const zeroForOne = sellToken.toLowerCase() === question.currency0.toLowerCase()

  const yesCurrency = question.yes.toLowerCase() === question.currency0.toLowerCase() ? 'currency0' : 'currency1'
  const prob        = balances ? yesProb(balances.sqrtPriceX96, yesCurrency as 'currency0' | 'currency1') : 50
  const price0in1   = balances
    ? (() => {
        const n = Number(balances.sqrtPriceX96)
        const d = Number(2n ** 96n)
        return (n / d) ** 2
      })()
    : 1

  // Human-readable current price
  const priceLabel = (() => {
    if (!balances || balances.sqrtPriceX96 === 0n) return '…'
    const isYesCur0 = question.yes.toLowerCase() === question.currency0.toLowerCase()
    const yesInNo = isYesCur0 ? price0in1 : (price0in1 === 0 ? 0 : 1 / price0in1)
    return `1 YES = ${yesInNo.toFixed(4)} NO`
  })()

  async function step1ERC20Approve() {
    if (!account) return
    setBusy(true); setError(null); setStatus(`Approving ${sellSymbol} → Permit2…`)
    try {
      const data = encodeApprove(ADDRESSES.PERMIT2, maxUint256)
      setStatus('Waiting for wallet…')
      const hash = await sendTx(sellToken as `0x${string}`, data, account)
      setTxHash(hash); setStatus('Confirming…')
      await waitForTx(hash)
      setStatus('Approved!'); await fetchBalances()
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err)); setStatus(null)
    } finally { setBusy(false) }
  }

  async function step2Permit2Approve() {
    if (!account) return
    setBusy(true); setError(null); setStatus(`Permit2: approving ${sellSymbol} → Universal Router…`)
    try {
      const data = encodePermit2Approve(sellToken as `0x${string}`, ADDRESSES.UNIVERSAL_ROUTER)
      setStatus('Waiting for wallet…')
      const hash = await sendTx(ADDRESSES.PERMIT2, data, account)
      setTxHash(hash); setStatus('Confirming…')
      await waitForTx(hash)
      setStatus('Permit2 approved!'); await fetchBalances()
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err)); setStatus(null)
    } finally { setBusy(false) }
  }

  async function executeSwap() {
    if (!account || amountBig === 0n) return
    setBusy(true); setError(null); setStatus(`Swapping ${sellSymbol} → ${buySymbol}…`)
    try {
      const deadline = BigInt(Math.floor(Date.now() / 1000) + 300)
      const data = encodeV4Swap({
        currency0:  question.currency0,
        currency1:  question.currency1,
        zeroForOne,
        amountIn:   amountBig,
        recipient:  account,
        deadline,
      })
      setStatus('Waiting for wallet…')
      const hash = await sendTx(ADDRESSES.UNIVERSAL_ROUTER, data, account)
      setTxHash(hash); setStatus('Confirming…')
      await waitForTx(hash)
      setStatus('Swap complete!'); await fetchBalances()
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err)); setStatus(null)
    } finally { setBusy(false) }
  }

  const step = needsErc20Approve ? 1 : needsPermit2Approve ? 2 : 3

  return (
    <div className="p-4 space-y-4 max-w-2xl mx-auto">

      {/* Price gauge */}
      <div className="bg-os-card border border-os-border rounded-xl p-4 space-y-3">
        <div className="flex items-center justify-between">
          <div className="text-xs font-semibold text-white">Pool Price</div>
          <div className="text-[11px] font-mono text-os-text">{priceLabel}</div>
        </div>

        {balances && balances.sqrtPriceX96 > 0n && (
          <>
            <div className="flex h-5 rounded-lg overflow-hidden border border-os-border">
              <div
                className="flex items-center justify-center text-[9px] font-bold text-white bg-os-yes transition-all duration-500"
                style={{ width: `${Math.max(4, prob)}%` }}
              >
                {prob.toFixed(0)}%
              </div>
              <div
                className="flex items-center justify-center text-[9px] font-bold text-white bg-os-no transition-all duration-500"
                style={{ width: `${Math.max(4, 100 - prob)}%` }}
              >
                {(100 - prob).toFixed(0)}%
              </div>
            </div>
            <div className="flex justify-between text-[10px] font-mono text-os-text">
              <span className="text-os-yes">P(YES) = {prob.toFixed(1)}%</span>
              <span className="text-os-no">P(NO) = {(100 - prob).toFixed(1)}%</span>
            </div>
          </>
        )}

        <div className="grid grid-cols-2 gap-2">
          <BalCard label="YES Balance" value={balances ? fmt6(balances.yes) : '…'} color="text-os-yes" />
          <BalCard label="NO Balance"  value={balances ? fmt6(balances.no)  : '…'} color="text-os-no" />
        </div>
      </div>

      {/* Direction toggle */}
      <div className="bg-os-card border border-os-border rounded-xl p-4 space-y-4">
        <div className="text-xs font-semibold text-white">Swap Direction</div>
        <div className="flex gap-2">
          <button
            onClick={() => setDirection('yes-to-no')}
            className={[
              'flex-1 py-2 text-xs font-semibold rounded-lg border transition-colors',
              direction === 'yes-to-no'
                ? 'bg-os-yes/20 border-os-yes/60 text-os-yes'
                : 'bg-os-bg border-os-border text-os-text hover:border-os-yes/30',
            ].join(' ')}
          >
            YES → NO
          </button>
          <button
            onClick={() => setDirection('no-to-yes')}
            className={[
              'flex-1 py-2 text-xs font-semibold rounded-lg border transition-colors',
              direction === 'no-to-yes'
                ? 'bg-os-blue/20 border-os-blue/60 text-os-blue'
                : 'bg-os-bg border-os-border text-os-text hover:border-os-blue/30',
            ].join(' ')}
          >
            NO → YES
          </button>
        </div>

        {/* Amount */}
        <div>
          <label className="block text-[11px] font-mono text-os-text mb-1">
            Amount ({sellSymbol} tokens, 6 decimals)
          </label>
          <input
            type="number"
            value={amount}
            onChange={e => setAmount(e.target.value)}
            className="w-full bg-os-bg border border-os-border rounded-lg px-3 py-2.5 text-sm text-white outline-none"
            placeholder="50"
          />
          <div className="text-[10px] font-mono text-os-text mt-0.5">= {amountBig.toString()} wei</div>
        </div>

        {/* 3-step approval + swap */}
        <div className="space-y-2">
          <div className="text-[10px] font-mono text-os-text uppercase tracking-wider">
            Step {step} of 3 — {step === 1 ? `Approve ${sellSymbol} → Permit2` : step === 2 ? `Permit2 → Universal Router` : 'Swap'}
          </div>

          <div className="flex gap-2">
            <button
              onClick={step1ERC20Approve}
              disabled={busy || !account || !onUnichain || !needsErc20Approve}
              className={[
                'flex-1 py-2 text-xs font-semibold rounded-lg border transition-colors disabled:opacity-40 disabled:cursor-not-allowed',
                step === 1
                  ? 'bg-os-blue/20 border-os-blue/60 text-os-blue hover:bg-os-blue/30'
                  : 'bg-os-bg border-os-border text-os-text/50',
              ].join(' ')}
            >
              {step > 1 ? '✓' : '1.'} Approve ERC20
            </button>
            <button
              onClick={step2Permit2Approve}
              disabled={busy || !account || !onUnichain || needsErc20Approve || !needsPermit2Approve}
              className={[
                'flex-1 py-2 text-xs font-semibold rounded-lg border transition-colors disabled:opacity-40 disabled:cursor-not-allowed',
                step === 2
                  ? 'bg-os-blue/20 border-os-blue/60 text-os-blue hover:bg-os-blue/30'
                  : 'bg-os-bg border-os-border text-os-text/50',
              ].join(' ')}
            >
              {step > 2 ? '✓' : '2.'} Permit2
            </button>
            <button
              onClick={executeSwap}
              disabled={busy || !account || !onUnichain || step < 3}
              className={[
                'flex-1 py-2 text-xs font-semibold rounded-lg border transition-colors disabled:opacity-40 disabled:cursor-not-allowed',
                step === 3
                  ? 'bg-os-yes/20 border-os-yes/60 text-os-yes hover:bg-os-yes/30'
                  : 'bg-os-bg border-os-border text-os-text/50',
              ].join(' ')}
            >
              3. Swap
            </button>
          </div>
        </div>

        {!account && <div className="text-[11px] text-yellow-400 font-mono">Connect wallet first.</div>}
        {account && !onUnichain && <div className="text-[11px] text-yellow-400 font-mono">Switch to Unichain Sepolia.</div>}

        {status && (
          <div className="flex items-center gap-2 text-[11px] font-mono text-os-blue">
            {busy && <span className="w-3 h-3 rounded-full border-2 border-os-blue border-t-transparent animate-spin inline-block" />}
            {status}
            {txHash && (
              <a href={blockscoutTx(txHash)} target="_blank" rel="noopener noreferrer" className="underline ml-1">view tx</a>
            )}
          </div>
        )}
        {error && <div className="text-[11px] font-mono text-os-no">{error}</div>}
      </div>

      {/* Info box */}
      <div className="bg-os-card border border-os-border rounded-xl p-3">
        <div className="text-[10px] text-os-text space-y-1">
          <div>• Swapping YES→NO drives the pool price of YES down (market says NO more likely)</div>
          <div>• Swapping NO→YES drives the pool price of YES up (market says YES more likely)</div>
          <div>• 1% pool fee. Swaps blocked after settlement — use Redeem tab to exit.</div>
          <div>• The pool price = implied probability gauge above</div>
        </div>
      </div>
    </div>
  )
}

function BalCard({ label, value, color }: { label: string; value: string; color: string }) {
  return (
    <div className="bg-os-bg border border-os-border rounded-lg p-2.5 text-center">
      <div className="text-[9px] font-mono text-os-text uppercase tracking-wider mb-1">{label}</div>
      <div className={['text-sm font-bold font-mono', color].join(' ')}>{value}</div>
    </div>
  )
}
