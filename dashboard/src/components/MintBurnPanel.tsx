import { useState, useEffect, useCallback } from 'react'
import {
  ADDRESSES, ERC20_ABI, VAULT_ABI, unichainClient,
  encodeApprove, encodeMint, encodeBurn,
  sendTx, waitForTx, blockscoutTx,
  QuestionState, fmt6, parseUnits, maxUint256, CHAIN_IDS,
} from '../constants'

interface Props {
  account:  `0x${string}` | null
  chainId:  number | null
  question: QuestionState
}

interface Balances {
  usdc: bigint
  yes:  bigint
  no:   bigint
  usdcAllow: bigint   // USDC allowance to vault
}

export default function MintBurnPanel({ account, chainId, question }: Props) {
  const [amount, setAmount]       = useState('100')
  const [balances, setBalances]   = useState<Balances | null>(null)
  const [busy, setBusy]           = useState(false)
  const [status, setStatus]       = useState<string | null>(null)
  const [txHash, setTxHash]       = useState<`0x${string}` | null>(null)
  const [error, setError]         = useState<string | null>(null)
  const [vaultSettled, setVaultSettled] = useState(false)

  const onUnichain = chainId === CHAIN_IDS.UNICHAIN

  const fetchBalances = useCallback(async () => {
    if (!account) return
    try {
      const [usdc, yes, no, usdcAllow, settled] = await Promise.all([
        unichainClient.readContract({ address: ADDRESSES.USDC, abi: ERC20_ABI, functionName: 'balanceOf', args: [account] }) as Promise<bigint>,
        unichainClient.readContract({ address: question.yes,   abi: ERC20_ABI, functionName: 'balanceOf', args: [account] }) as Promise<bigint>,
        unichainClient.readContract({ address: question.no,    abi: ERC20_ABI, functionName: 'balanceOf', args: [account] }) as Promise<bigint>,
        unichainClient.readContract({ address: ADDRESSES.USDC, abi: ERC20_ABI, functionName: 'allowance', args: [account, question.vault] }) as Promise<bigint>,
        unichainClient.readContract({ address: question.vault, abi: VAULT_ABI, functionName: 'settled',   args: [] }) as Promise<boolean>,
      ])
      setBalances({ usdc, yes, no, usdcAllow })
      setVaultSettled(settled)
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

  const needsApproval = balances !== null && balances.usdcAllow < amountBig

  async function approveUsdc() {
    if (!account) return
    setBusy(true); setError(null); setStatus('Approving USDC…')
    try {
      const data = encodeApprove(question.vault as `0x${string}`, maxUint256)
      setStatus('Waiting for wallet…')
      const hash = await sendTx(ADDRESSES.USDC, data, account)
      setTxHash(hash); setStatus('Confirming…')
      await waitForTx(hash)
      setStatus('Approved!'); await fetchBalances()
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err)); setStatus(null)
    } finally { setBusy(false) }
  }

  async function mintTokens() {
    if (!account || amountBig === 0n) return
    setBusy(true); setError(null); setStatus('Minting YES+NO…')
    try {
      const data = encodeMint(amountBig)
      setStatus('Waiting for wallet…')
      const hash = await sendTx(question.vault as `0x${string}`, data, account)
      setTxHash(hash); setStatus('Confirming…')
      await waitForTx(hash)
      setStatus('Minted!'); await fetchBalances()
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err)); setStatus(null)
    } finally { setBusy(false) }
  }

  async function burnTokens() {
    if (!account || amountBig === 0n) return
    setBusy(true); setError(null); setStatus('Burning YES+NO…')
    try {
      const data = encodeBurn(amountBig)
      setStatus('Waiting for wallet…')
      const hash = await sendTx(question.vault as `0x${string}`, data, account)
      setTxHash(hash); setStatus('Confirming…')
      await waitForTx(hash)
      setStatus('Burned! USDC returned.'); await fetchBalances()
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err)); setStatus(null)
    } finally { setBusy(false) }
  }

  return (
    <div className="p-4 space-y-4 max-w-2xl mx-auto">

      {/* Balances */}
      <div className="bg-os-card border border-os-border rounded-xl p-4">
        <div className="text-xs font-semibold text-white mb-3">Your Balances</div>
        <div className="grid grid-cols-3 gap-2">
          <BalCard label="USDC" value={balances ? fmt6(balances.usdc) : '…'} color="text-white" />
          <BalCard label="YES"  value={balances ? fmt6(balances.yes)  : '…'} color="text-os-yes" />
          <BalCard label="NO"   value={balances ? fmt6(balances.no)   : '…'} color="text-os-no" />
        </div>
        {balances && (
          <div className="mt-2 text-[10px] font-mono text-os-text">
            USDC allowance to vault: {fmt6(balances.usdcAllow)}
          </div>
        )}
      </div>

      {/* Amount input */}
      <div className="bg-os-card border border-os-border rounded-xl p-4 space-y-3">
        <div className="text-xs font-semibold text-white">Amount (USDC = YES = NO, 6 decimals)</div>
        <div className="flex items-center bg-os-bg border border-os-border rounded-lg overflow-hidden">
          <input
            type="number"
            value={amount}
            onChange={e => setAmount(e.target.value)}
            placeholder="100"
            className="flex-1 bg-transparent px-3 py-2.5 text-sm text-white outline-none"
          />
          <span className="px-3 text-xs text-os-text">USDC</span>
        </div>
        <div className="text-[10px] font-mono text-os-text">= {amountBig.toString()} wei (6 dec)</div>

        {!account && <div className="text-[11px] text-yellow-400 font-mono">Connect wallet first.</div>}
        {account && !onUnichain && <div className="text-[11px] text-yellow-400 font-mono">Switch to Unichain Sepolia.</div>}

        {/* Mint flow */}
        <div className="space-y-2">
          <div className="text-[10px] font-mono text-os-text uppercase tracking-wider">Mint (USDC → YES + NO)</div>
          <div className="flex gap-2">
            {needsApproval && (
              <button
                onClick={approveUsdc}
                disabled={busy || !account || !onUnichain}
                className="flex-1 py-2 text-xs font-semibold bg-os-blue/20 hover:bg-os-blue/30 border border-os-blue/40 text-os-blue rounded-lg transition-colors disabled:opacity-40"
              >
                {busy && status?.includes('Approv') ? 'Approving…' : '1. Approve USDC'}
              </button>
            )}
            <button
              onClick={mintTokens}
              disabled={busy || !account || !onUnichain || needsApproval}
              className="flex-1 py-2 text-xs font-semibold bg-os-yes/20 hover:bg-os-yes/30 border border-os-yes/40 text-os-yes rounded-lg transition-colors disabled:opacity-40"
            >
              {needsApproval ? '2. Mint YES+NO' : 'Mint YES+NO'}
            </button>
          </div>
        </div>

        {/* Burn flow */}
        <div className="space-y-2">
          <div className="text-[10px] font-mono text-os-text uppercase tracking-wider">
            Burn (YES + NO → USDC) — pre-settlement only
          </div>
          <button
            onClick={burnTokens}
            disabled={busy || !account || !onUnichain || vaultSettled}
            className="w-full py-2 text-xs font-semibold bg-os-no/20 hover:bg-os-no/30 border border-os-no/40 text-os-no rounded-lg transition-colors disabled:opacity-40"
          >
            {vaultSettled ? 'Market settled — use Redeem tab' : 'Burn YES+NO → USDC'}
          </button>
        </div>

        {status && (
          <div className="flex items-center gap-2 text-[11px] font-mono text-os-blue">
            {busy && <span className="w-3 h-3 rounded-full border-2 border-os-blue border-t-transparent animate-spin inline-block" />}
            {status}
            {txHash && (
              <a href={blockscoutTx(txHash)} target="_blank" rel="noopener noreferrer" className="underline ml-1">
                view tx
              </a>
            )}
          </div>
        )}
        {error && <div className="text-[11px] font-mono text-os-no">{error}</div>}
      </div>

      {/* Info box */}
      <div className="bg-os-card border border-os-border rounded-xl p-3">
        <div className="text-[10px] text-os-text space-y-1">
          <div>• <strong className="text-white">Mint</strong>: deposit N USDC → receive N YES + N NO tokens</div>
          <div>• <strong className="text-white">Burn</strong>: return N YES + N NO → receive N USDC (pre-settlement exit)</div>
          <div>• After acquiring YES and NO, go to <strong className="text-white">Trade</strong> to swap them on the AMM</div>
          <div>• After settlement, use the <strong className="text-white">Redeem</strong> tab to claim USDC with your winning tokens</div>
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
