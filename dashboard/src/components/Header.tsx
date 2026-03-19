import { ADDRESSES, CHAIN_IDS } from '../constants'

export type Tab = 'market' | 'mint' | 'trade' | 'redeem'

interface Props {
  activeTab:        Tab
  onTabChange:      (t: Tab) => void
  account:          `0x${string}` | null
  chainId:          number | null
  onConnect:        () => void
  onSwitchUnichain: () => void
  hasQuestion:      boolean
}

const TABS: { id: Tab; label: string; emoji: string }[] = [
  { id: 'market', label: 'Market',   emoji: '🏛' },
  { id: 'mint',   label: 'Mint/Burn', emoji: '⚗️' },
  { id: 'trade',  label: 'Trade',    emoji: '↔️' },
  { id: 'redeem', label: 'Redeem',   emoji: '🏆' },
]

export default function Header({
  activeTab, onTabChange, account, chainId, onConnect, onSwitchUnichain, hasQuestion,
}: Props) {
  const onUnichain = chainId === CHAIN_IDS.UNICHAIN
  const shortAddr  = account ? account.slice(0, 6) + '…' + account.slice(-4) : null

  return (
    <header className="border-b border-os-border bg-os-bg sticky top-0 z-40">
      {/* Top bar */}
      <div className="flex items-center justify-between px-4 py-3">
        {/* Logo */}
        <div className="flex items-center gap-3">
          <div className="w-8 h-8 rounded-lg bg-os-blue flex items-center justify-center text-sm font-bold">O</div>
          <div>
            <div className="text-sm font-semibold text-white leading-none">OracleSettle</div>
            <div className="text-[10px] font-mono text-os-text mt-0.5">Prediction Market</div>
          </div>
        </div>

        {/* Chain + Wallet */}
        <div className="flex items-center gap-2">
          {account && !onUnichain && (
            <button
              onClick={onSwitchUnichain}
              className="px-2.5 py-1 text-[11px] font-mono bg-yellow-500/10 text-yellow-400 border border-yellow-500/30 rounded hover:bg-yellow-500/20 transition-colors"
            >
              Switch to Unichain
            </button>
          )}
          {account && onUnichain && (
            <div className="flex items-center gap-1.5 px-2.5 py-1 bg-os-blue/10 border border-os-blue/30 rounded text-[11px] font-mono text-os-blue">
              <span className="w-1.5 h-1.5 rounded-full bg-os-blue animate-pulse-dot inline-block" />
              Unichain Sepolia
            </div>
          )}
          {account ? (
            <div className="px-2.5 py-1 bg-os-card border border-os-border rounded text-[11px] font-mono text-os-text">
              {shortAddr}
            </div>
          ) : (
            <button
              onClick={onConnect}
              className="px-3 py-1.5 text-xs font-semibold bg-os-blue hover:bg-blue-500 text-white rounded transition-colors"
            >
              Connect Wallet
            </button>
          )}
        </div>
      </div>

      {/* Tab bar */}
      <div className="flex items-center gap-1 px-4 pb-0">
        {TABS.map(tab => {
          const disabled = tab.id !== 'market' && !hasQuestion
          return (
            <button
              key={tab.id}
              onClick={() => !disabled && onTabChange(tab.id)}
              disabled={disabled}
              className={[
                'flex items-center gap-1.5 px-3 py-2 text-xs font-medium rounded-t transition-colors border-b-2',
                activeTab === tab.id
                  ? 'text-white border-os-blue bg-os-blue/10'
                  : disabled
                    ? 'text-os-text/30 border-transparent cursor-not-allowed'
                    : 'text-os-text border-transparent hover:text-white hover:border-os-border',
              ].join(' ')}
            >
              <span>{tab.emoji}</span>
              <span>{tab.label}</span>
            </button>
          )
        })}
      </div>

      {/* Contract strip */}
      <div className="flex items-center gap-3 px-4 py-1.5 text-[9px] font-mono text-os-text/50 border-t border-os-border/50 overflow-x-auto">
        <span>Hook: {ADDRESSES.HOOK.slice(0, 10)}…</span>
        <span>Factory: {ADDRESSES.FACTORY.slice(0, 10)}…</span>
        <span>USDC: {ADDRESSES.USDC.slice(0, 10)}…</span>
      </div>
    </header>
  )
}
