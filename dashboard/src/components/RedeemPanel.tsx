import { useState, useEffect, useCallback } from 'react'
import {
  ADDRESSES, ERC20_ABI, VAULT_ABI, HOOK_ABI, unichainClient, buildPoolKey,
  encodeRedeem, sendTx, waitForTx, blockscoutTx,
  QuestionState, fmt6, fmtPrice8, parseUnits, CHAIN_IDS,
} from '../constants'

interface Props {
  account:  `0x${string}` | null
  chainId:  number | null
  question: QuestionState
}

interface RedeemState {
  settled:   boolean
  yesWon:    boolean
  yesBalance: bigint
  noBalance:  bigint
  usdcBalance: bigint
  targetPrice: bigint
  settledPrice: bigint
  phase:     number
}

export default function RedeemPanel({ account, chainId, question }: Props) {
  const [state, setState]   = useState<RedeemState | null>(null)
  const [amount, setAmount] = useState('')
  const [busy, setBusy]     = useState(false)
  const [status, setStatus] = useState<string | null>(null)
  const [txHash, setTxHash] = useState<`0x${string}` | null>(null)
  const [error, setError]   = useState<string | null>(null)

  const onUnichain = chainId === CHAIN_IDS.UNICHAIN

  const fetchState = useCallback(async () => {
    if (!account) return
    try {
      const key = buildPoolKey(question)
      const [settled, yesWon, yesBalance, noBalance, usdcBalance, marketState] = await Promise.all([
        unichainClient.readContract({ address: question.vault, abi: VAULT_ABI, functionName: 'settled',   args: [] }) as Promise<boolean>,
        unichainClient.readContract({ address: question.vault, abi: VAULT_ABI, functionName: 'yesWon',    args: [] }) as Promise<boolean>,
        unichainClient.readContract({ address: question.yes,   abi: ERC20_ABI, functionName: 'balanceOf', args: [account] }) as Promise<bigint>,
        unichainClient.readContract({ address: question.no,    abi: ERC20_ABI, functionName: 'balanceOf', args: [account] }) as Promise<bigint>,
        unichainClient.readContract({ address: ADDRESSES.USDC, abi: ERC20_ABI, functionName: 'balanceOf', args: [account] }) as Promise<bigint>,
        unichainClient.readContract({
          address:      ADDRESSES.HOOK,
          abi:          HOOK_ABI,
          functionName: 'getMarketState',
          args:         [key as never],
        }) as Promise<{ phase: number; targetPrice: bigint; settledPrice: bigint }>,
      ])
      setState({
        settled, yesWon, yesBalance, noBalance, usdcBalance,
        targetPrice:  marketState.targetPrice,
        settledPrice: marketState.settledPrice,
        phase:        marketState.phase,
      })
    } catch { /* ignore */ }
  }, [account, question])

  useEffect(() => {
    fetchState()
    const iv = setInterval(fetchState, 8000)
    return () => clearInterval(iv)
  }, [fetchState])

  const winningBalance = state ? (state.yesWon ? state.yesBalance : state.noBalance) : 0n
  const winnerSymbol   = state?.yesWon ? 'YES' : 'NO'

  const amountBig = (() => {
    try { return parseUnits(amount || '0', 6) } catch { return 0n }
  })()

  function setMax() {
    if (!state) return
    const bal = state.settled ? winningBalance : (state.yesBalance < state.noBalance ? state.yesBalance : state.noBalance)
    setAmount((Number(bal) / 1e6).toFixed(6).replace(/\.?0+$/, ''))
  }

  async function redeem() {
    if (!account || amountBig === 0n) return
    setBusy(true); setError(null); setStatus('Redeeming…')
    try {
      const data = encodeRedeem(amountBig)
      setStatus('Waiting for wallet…')
      const hash = await sendTx(question.vault as `0x${string}`, data, account)
      setTxHash(hash); setStatus('Confirming…')
      await waitForTx(hash)
      setStatus('Redeemed! USDC received.'); await fetchState()
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err)); setStatus(null)
    } finally { setBusy(false) }
  }

  return (
    <div className="p-4 space-y-4 max-w-2xl mx-auto">

      {/* Settlement status */}
      <div className="bg-os-card border border-os-border rounded-xl p-4 space-y-3">
        <div className="flex items-center justify-between">
          <div className="text-xs font-semibold text-white">Settlement Status</div>
          {state && (
            <span className={[
              'px-2 py-0.5 text-[10px] font-mono rounded-full border',
              state.settled
                ? 'bg-os-yes-dim text-os-yes border-os-yes/30'
                : 'bg-os-blue-dim text-os-blue border-os-blue/30',
            ].join(' ')}>
              {state.settled ? 'SETTLED' : 'TRADING'}
            </span>
          )}
        </div>

        {!state && (
          <div className="text-[11px] font-mono text-os-text animate-pulse">Loading…</div>
        )}

        {state && !state.settled && (
          <div className="space-y-2">
            <div className="text-[11px] text-os-text">
              Market has not settled yet. The Reactive RSC monitors Chainlink ETH/USD on Ethereum Sepolia
              and will trigger settlement once the price is reported at or after expiry.
            </div>
            <div className="grid grid-cols-2 gap-2 text-[11px]">
              <Detail label="Target Price" value={fmtPrice8(state.targetPrice)} />
              <Detail label="Pool Phase"   value={state.phase === 0 ? 'TRADING' : 'RESOLVED'} />
            </div>
            <div className="bg-yellow-500/5 border border-yellow-500/20 rounded-lg p-2">
              <div className="text-[10px] text-yellow-400">
                Once settled, swaps are blocked. Come back to redeem your winning tokens here.
              </div>
            </div>
          </div>
        )}

        {state && state.settled && (
          <div className="space-y-3">
            {/* Outcome banner */}
            <div className={[
              'rounded-xl p-4 text-center border',
              state.yesWon
                ? 'bg-os-yes-dim border-os-yes/30'
                : 'bg-os-no-dim border-os-no/30',
            ].join(' ')}>
              <div className={['text-2xl font-bold', state.yesWon ? 'text-os-yes' : 'text-os-no'].join(' ')}>
                {state.yesWon ? '✅ YES WON' : '❌ NO WON'}
              </div>
              <div className="text-xs text-os-text mt-1">
                Settled price: <strong className="text-white">{fmtPrice8(state.settledPrice)}</strong>
                {' '}— Target: <strong className="text-white">{fmtPrice8(state.targetPrice)}</strong>
              </div>
            </div>

            {/* Balances */}
            <div className="grid grid-cols-3 gap-2">
              <BalCard label="YES" value={fmt6(state.yesBalance)} color={state.yesWon ? 'text-os-yes' : 'text-os-text/50'} />
              <BalCard label="NO"  value={fmt6(state.noBalance)}  color={state.yesWon ? 'text-os-text/50' : 'text-os-no'} />
              <BalCard label="USDC" value={fmt6(state.usdcBalance)} color="text-white" />
            </div>

            {/* Redeem form */}
            <div className="space-y-3">
              <div className="text-[11px] text-os-text">
                Burn your <strong className={state.yesWon ? 'text-os-yes' : 'text-os-no'}>{winnerSymbol}</strong> tokens
                to receive USDC 1:1 from the vault.
                You have <strong className="text-white">{fmt6(winningBalance)} {winnerSymbol}</strong>.
              </div>

              <div className="flex gap-2">
                <input
                  type="number"
                  value={amount}
                  onChange={e => setAmount(e.target.value)}
                  placeholder={`${winnerSymbol} amount`}
                  className="flex-1 bg-os-bg border border-os-border rounded-lg px-3 py-2.5 text-sm text-white outline-none"
                />
                <button
                  onClick={setMax}
                  className="px-3 py-2 text-xs font-mono text-os-text border border-os-border rounded-lg hover:border-os-blue hover:text-white transition-colors"
                >
                  Max
                </button>
              </div>

              <button
                onClick={redeem}
                disabled={busy || !account || !onUnichain || winningBalance === 0n || amountBig === 0n}
                className={[
                  'w-full py-2.5 text-sm font-semibold rounded-lg border transition-colors disabled:opacity-40 disabled:cursor-not-allowed',
                  state.yesWon
                    ? 'bg-os-yes/20 hover:bg-os-yes/30 border-os-yes/50 text-os-yes'
                    : 'bg-os-no/20 hover:bg-os-no/30 border-os-no/50 text-os-no',
                ].join(' ')}
              >
                {busy ? 'Redeeming…' : `Redeem ${winnerSymbol} → USDC`}
              </button>

              {winningBalance === 0n && (
                <div className="text-[11px] font-mono text-os-text text-center">
                  No {winnerSymbol} tokens to redeem. {state.yesWon ? 'You held NO tokens.' : 'You held YES tokens.'}
                </div>
              )}
            </div>
          </div>
        )}

        {!account && <div className="text-[11px] text-yellow-400 font-mono">Connect wallet to see your balances.</div>}
        {account && !onUnichain && <div className="text-[11px] text-yellow-400 font-mono">Switch to Unichain Sepolia.</div>}

        {status && (
          <div className="flex items-center gap-2 text-[11px] font-mono text-os-blue mt-2">
            {busy && <span className="w-3 h-3 rounded-full border-2 border-os-blue border-t-transparent animate-spin inline-block" />}
            {status}
            {txHash && (
              <a href={blockscoutTx(txHash)} target="_blank" rel="noopener noreferrer" className="underline ml-1">view tx</a>
            )}
          </div>
        )}
        {error && <div className="text-[11px] font-mono text-os-no mt-2">{error}</div>}
      </div>

      {/* How it works */}
      <div className="bg-os-card border border-os-border rounded-xl p-3">
        <div className="text-[10px] font-semibold text-white mb-2">How Settlement Works</div>
        <div className="text-[10px] text-os-text space-y-1">
          <div>1. <strong className="text-white">OracleSettleReactive</strong> runs on Reactive Network (Lasna)</div>
          <div>2. It monitors <strong className="text-white">Chainlink AnswerUpdated</strong> on Ethereum Sepolia</div>
          <div>3. At expiry, it reads the price and determines YES or NO wins (price ≥ target?)</div>
          <div>4. Reactive emits a <strong className="text-white">cross-chain callback</strong> → OracleSettleCallback on Unichain</div>
          <div>5. Callback calls <strong className="text-white">OracleSettleHook.settle()</strong> → marks pool RESOLVED + calls vault.settle()</div>
          <div>6. Winners can now call <strong className="text-white">vault.redeem()</strong> to receive USDC 1:1</div>
        </div>
      </div>
    </div>
  )
}

function Detail({ label, value }: { label: string; value: string }) {
  return (
    <div className="bg-os-bg border border-os-border rounded-lg p-2">
      <div className="text-[9px] font-mono text-os-text uppercase tracking-wider mb-0.5">{label}</div>
      <div className="text-xs text-white font-semibold">{value}</div>
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
