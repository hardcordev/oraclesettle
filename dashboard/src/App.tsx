import { useState, useEffect } from 'react'
import { motion, AnimatePresence } from 'framer-motion'
import Header, { type Tab } from './components/Header'
import MarketPanel  from './components/MarketPanel'
import MintBurnPanel from './components/MintBurnPanel'
import TradePanel   from './components/TradePanel'
import RedeemPanel  from './components/RedeemPanel'
import { useWallet } from './hooks/useWallet'
import { loadQuestion, QuestionState } from './constants'

export default function App() {
  const [activeTab, setActiveTab] = useState<Tab>('market')
  const [question, setQuestion]   = useState<QuestionState | null>(null)

  const wallet = useWallet()

  // Load persisted question on mount
  useEffect(() => {
    const q = loadQuestion()
    if (q) setQuestion(q)
  }, [])

  function handleQuestion(q: QuestionState | null) {
    setQuestion(q)
    if (q && activeTab === 'market') setActiveTab('mint')
  }

  return (
    <div className="min-h-screen bg-os-bg text-white flex flex-col">
      <Header
        activeTab={activeTab}
        onTabChange={setActiveTab}
        account={wallet.account}
        chainId={wallet.chainId}
        onConnect={wallet.connect}
        onSwitchUnichain={wallet.switchToUnichain}
        hasQuestion={question !== null}
      />

      <main className="flex-1 overflow-y-auto">
        <AnimatePresence mode="wait">
          {activeTab === 'market' && (
            <motion.div
              key="market"
              initial={{ opacity: 0, y: 8 }}
              animate={{ opacity: 1, y: 0 }}
              exit={{ opacity: 0, y: -8 }}
              transition={{ duration: 0.15 }}
            >
              <MarketPanel
                account={wallet.account}
                chainId={wallet.chainId}
                question={question}
                onQuestion={handleQuestion}
              />
            </motion.div>
          )}

          {activeTab === 'mint' && question && (
            <motion.div
              key="mint"
              initial={{ opacity: 0, y: 8 }}
              animate={{ opacity: 1, y: 0 }}
              exit={{ opacity: 0, y: -8 }}
              transition={{ duration: 0.15 }}
            >
              <MintBurnPanel
                account={wallet.account}
                chainId={wallet.chainId}
                question={question}
              />
            </motion.div>
          )}

          {activeTab === 'trade' && question && (
            <motion.div
              key="trade"
              initial={{ opacity: 0, y: 8 }}
              animate={{ opacity: 1, y: 0 }}
              exit={{ opacity: 0, y: -8 }}
              transition={{ duration: 0.15 }}
            >
              <TradePanel
                account={wallet.account}
                chainId={wallet.chainId}
                question={question}
              />
            </motion.div>
          )}

          {activeTab === 'redeem' && question && (
            <motion.div
              key="redeem"
              initial={{ opacity: 0, y: 8 }}
              animate={{ opacity: 1, y: 0 }}
              exit={{ opacity: 0, y: -8 }}
              transition={{ duration: 0.15 }}
            >
              <RedeemPanel
                account={wallet.account}
                chainId={wallet.chainId}
                question={question}
              />
            </motion.div>
          )}
        </AnimatePresence>
      </main>

      {/* Footer */}
      <footer className="border-t border-os-border px-4 py-2 flex items-center justify-between flex-shrink-0">
        <div className="flex items-center gap-3 text-[10px] font-mono text-os-text/60">
          <span>Hook: 0x51C6…e080</span>
          <span className="hidden sm:inline">Unichain Sepolia · Ethereum Sepolia · Reactive Lasna</span>
        </div>
        <div className="text-[10px] font-mono text-os-text/60">OracleSettle · UHI8</div>
      </footer>
    </div>
  )
}
