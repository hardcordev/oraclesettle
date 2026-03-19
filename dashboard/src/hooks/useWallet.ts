import { useState, useEffect, useCallback } from 'react'
import { getAccounts, switchChain, CHAIN_IDS } from '../constants'

export interface WalletState {
  account:    `0x${string}` | null
  chainId:    number | null
  connected:  boolean
  connecting: boolean
  error:      string | null
}

export interface WalletActions {
  connect:          () => Promise<void>
  switchToUnichain: () => Promise<void>
}

export function useWallet(): WalletState & WalletActions {
  const [state, setState] = useState<WalletState>({
    account:    null,
    chainId:    null,
    connected:  false,
    connecting: false,
    error:      null,
  })

  const readState = useCallback(async () => {
    if (!window.ethereum) return
    try {
      const [accounts, chainIdHex] = await Promise.all([
        window.ethereum.request({ method: 'eth_accounts' }) as Promise<string[]>,
        window.ethereum.request({ method: 'eth_chainId'  }) as Promise<string>,
      ])
      const account = accounts[0] as `0x${string}` | undefined
      const chainId = parseInt(chainIdHex, 16)
      setState(prev => ({ ...prev, account: account ?? null, chainId, connected: !!account }))
    } catch { /* ignore */ }
  }, [])

  useEffect(() => {
    readState()
    if (!window.ethereum) return
    const onAccounts = (accounts: unknown) => {
      const list = accounts as string[]
      setState(prev => ({
        ...prev,
        account:   list[0] as `0x${string}` | undefined ?? null,
        connected: list.length > 0,
      }))
    }
    const onChain = (chainIdHex: unknown) => {
      setState(prev => ({ ...prev, chainId: parseInt(chainIdHex as string, 16) }))
    }
    window.ethereum.on('accountsChanged', onAccounts)
    window.ethereum.on('chainChanged', onChain)
    return () => {
      window.ethereum?.removeListener('accountsChanged', onAccounts)
      window.ethereum?.removeListener('chainChanged', onChain)
    }
  }, [readState])

  const connect = useCallback(async () => {
    setState(prev => ({ ...prev, connecting: true, error: null }))
    try {
      const accounts   = await getAccounts()
      const chainIdHex = await window.ethereum!.request({ method: 'eth_chainId' }) as string
      setState({
        account:    accounts[0] ?? null,
        chainId:    parseInt(chainIdHex, 16),
        connected:  accounts.length > 0,
        connecting: false,
        error:      null,
      })
    } catch (err) {
      setState(prev => ({
        ...prev,
        connecting: false,
        error: err instanceof Error ? err.message : 'Connection failed',
      }))
    }
  }, [])

  const switchToUnichain = useCallback(async () => {
    try {
      await switchChain(CHAIN_IDS.UNICHAIN)
    } catch (err) {
      setState(prev => ({
        ...prev,
        error: err instanceof Error ? err.message : 'Switch failed',
      }))
    }
  }, [])

  return { ...state, connect, switchToUnichain }
}
