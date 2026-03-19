import {
  createPublicClient,
  http,
  defineChain,
  encodeFunctionData,
  encodeAbiParameters,
  encodePacked,
  keccak256,
  parseUnits,
  maxUint256,
} from 'viem'

// ── Chain ─────────────────────────────────────────────────────────────────────

export const unichainSepolia = defineChain({
  id: 1301,
  name: 'Unichain Sepolia',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: { default: { http: ['https://sepolia.unichain.org'] } },
  blockExplorers: {
    default: { name: 'Blockscout', url: 'https://unichain-sepolia.blockscout.com' },
  },
})

export const unichainClient = createPublicClient({
  chain: unichainSepolia,
  transport: http('https://sepolia.unichain.org'),
})

// ── Deployed addresses (Phase 1) ──────────────────────────────────────────────

export const ADDRESSES = {
  HOOK:            '0x51C69Fcca69484F3598DFA0DA1A92c57104eE080' as `0x${string}`,
  CALLBACK:        '0x7dB257225aBC3B4e31f4d97b97e1c60BEec3549e' as `0x${string}`,
  FACTORY:         '0x99C0756b7fda5a49bd8368EBc3d37e1B3Ee8498B' as `0x${string}`,
  USDC:            '0x31d0220469e10c4E71834a79b1f276d740d3768F' as `0x${string}`,
  POOL_MANAGER:    '0x00B036B58a818B1BC34d502D3fE730Db729e62AC' as `0x${string}`,
  POSITION_MGR:    '0xf969Aee60879C54bAAed9F3eD26147Db216Fd664' as `0x${string}`,
  PERMIT2:         '0x000000000022D473030F116dDEE9F6B43aC78BA3' as `0x${string}`,
  UNIVERSAL_ROUTER:'0xF8A776B85F97d85D0aAaB9b9fC5aB9DD73Ba8f0d' as `0x${string}`,
} as const

export const CHAIN_IDS = {
  UNICHAIN: 1301,
} as const

// Pool constants (from QuestionFactory)
export const POOL_FEE         = 10_000    // 1%
export const TICK_SPACING     = 200
export const SQRT_PRICE_1_1   = 79_228_162_514_264_337_593_543_950_336n  // sqrt(1) * 2^96

// ── Question state (persisted to localStorage) ────────────────────────────────

export interface QuestionState {
  questionId: number
  vault:       `0x${string}`
  yes:         `0x${string}`
  no:          `0x${string}`
  poolId:      `0x${string}`
  // sorted pool key fields (currency0 < currency1)
  currency0:   `0x${string}`
  currency1:   `0x${string}`
  targetPrice: string   // raw int256 as decimal string (e.g. "500000000000" for $5,000)
  expiry:      number   // unix timestamp
}

const LS_KEY = 'oraclesettle_question'

export function saveQuestion(q: QuestionState): void {
  localStorage.setItem(LS_KEY, JSON.stringify(q, (_, v) => typeof v === 'bigint' ? v.toString() : v))
}

export function loadQuestion(): QuestionState | null {
  try {
    const s = localStorage.getItem(LS_KEY)
    return s ? JSON.parse(s) : null
  } catch { return null }
}

export function clearQuestion(): void {
  localStorage.removeItem(LS_KEY)
}

// ── ABIs ──────────────────────────────────────────────────────────────────────

export const ERC20_ABI = [
  { name: 'balanceOf',  type: 'function', stateMutability: 'view',
    inputs: [{ name: 'account', type: 'address' }],
    outputs: [{ name: '', type: 'uint256' }] },
  { name: 'allowance',  type: 'function', stateMutability: 'view',
    inputs: [{ name: 'owner', type: 'address' }, { name: 'spender', type: 'address' }],
    outputs: [{ name: '', type: 'uint256' }] },
  { name: 'approve',    type: 'function', stateMutability: 'nonpayable',
    inputs: [{ name: 'spender', type: 'address' }, { name: 'amount', type: 'uint256' }],
    outputs: [{ name: '', type: 'bool' }] },
  { name: 'decimals',   type: 'function', stateMutability: 'view',
    inputs: [], outputs: [{ name: '', type: 'uint8' }] },
  { name: 'symbol',     type: 'function', stateMutability: 'view',
    inputs: [], outputs: [{ name: '', type: 'string' }] },
] as const

export const FACTORY_ABI = [
  { name: 'create',       type: 'function', stateMutability: 'nonpayable',
    inputs: [{ name: 'targetPrice', type: 'int256' }, { name: 'expiry', type: 'uint256' }],
    outputs: [
      { name: 'questionId', type: 'uint256' },
      { name: 'vault',      type: 'address' },
      { name: 'encodedKey', type: 'bytes'   },
    ] },
  { name: 'questions',    type: 'function', stateMutability: 'view',
    inputs: [{ name: '', type: 'uint256' }],
    outputs: [
      { name: 'vault',  type: 'address' },
      { name: 'yes',    type: 'address' },
      { name: 'no',     type: 'address' },
      { name: 'poolId', type: 'bytes32' },
    ] },
  { name: 'questionCount', type: 'function', stateMutability: 'view',
    inputs: [], outputs: [{ name: '', type: 'uint256' }] },
  // Event
  { name: 'QuestionCreated', type: 'event',
    inputs: [
      { name: 'questionId', type: 'uint256', indexed: true },
      { name: 'vault',      type: 'address', indexed: false },
      { name: 'yes',        type: 'address', indexed: false },
      { name: 'no',         type: 'address', indexed: false },
      { name: 'poolId',     type: 'bytes32', indexed: false },
    ] },
] as const

export const VAULT_ABI = [
  { name: 'mint',      type: 'function', stateMutability: 'nonpayable',
    inputs: [{ name: 'amount', type: 'uint256' }], outputs: [] },
  { name: 'burn',      type: 'function', stateMutability: 'nonpayable',
    inputs: [{ name: 'amount', type: 'uint256' }], outputs: [] },
  { name: 'redeem',    type: 'function', stateMutability: 'nonpayable',
    inputs: [{ name: 'amount', type: 'uint256' }], outputs: [] },
  { name: 'settled',   type: 'function', stateMutability: 'view',
    inputs: [], outputs: [{ name: '', type: 'bool' }] },
  { name: 'yesWon',    type: 'function', stateMutability: 'view',
    inputs: [], outputs: [{ name: '', type: 'bool' }] },
  { name: 'usdc',      type: 'function', stateMutability: 'view',
    inputs: [], outputs: [{ name: '', type: 'address' }] },
  { name: 'yesToken',  type: 'function', stateMutability: 'view',
    inputs: [], outputs: [{ name: '', type: 'address' }] },
  { name: 'noToken',   type: 'function', stateMutability: 'view',
    inputs: [], outputs: [{ name: '', type: 'address' }] },
] as const

// PoolKey tuple for ABI encoding
const POOL_KEY_TUPLE = {
  type: 'tuple',
  components: [
    { name: 'currency0',   type: 'address' },
    { name: 'currency1',   type: 'address' },
    { name: 'fee',         type: 'uint24'  },
    { name: 'tickSpacing', type: 'int24'   },
    { name: 'hooks',       type: 'address' },
  ],
} as const

// MarketState struct returned by getMarketState
// Phase: 0 = TRADING, 1 = RESOLVED
const MARKET_STATE_TUPLE = {
  type: 'tuple',
  components: [
    { name: 'phase',            type: 'uint8'   },
    { name: 'yesWon',           type: 'bool'    },
    { name: 'targetPrice',      type: 'int256'  },
    { name: 'expiryTimestamp',  type: 'uint256' },
    { name: 'settledPrice',     type: 'int256'  },
    { name: 'initialized',      type: 'bool'    },
    { name: 'vault',            type: 'address' },
  ],
} as const

export const HOOK_ABI = [
  { name: 'getMarketState', type: 'function', stateMutability: 'view',
    inputs: [{ name: 'key', ...POOL_KEY_TUPLE }],
    outputs: [{ name: '', ...MARKET_STATE_TUPLE }] },
  { name: 'owner',          type: 'function', stateMutability: 'view',
    inputs: [], outputs: [{ name: '', type: 'address' }] },
  // Events
  { name: 'MarketInitialized', type: 'event',
    inputs: [
      { name: 'poolId',      type: 'bytes32', indexed: true },
      { name: 'targetPrice', type: 'int256',  indexed: false },
      { name: 'expiry',      type: 'uint256', indexed: false },
    ] },
  { name: 'MarketSettled', type: 'event',
    inputs: [
      { name: 'poolId',       type: 'bytes32', indexed: true },
      { name: 'yesWon',       type: 'bool',    indexed: false },
      { name: 'settledPrice', type: 'int256',  indexed: false },
    ] },
] as const

export const POOL_MANAGER_ABI = [
  { name: 'getSlot0', type: 'function', stateMutability: 'view',
    inputs: [{ name: 'id', type: 'bytes32' }],
    outputs: [
      { name: 'sqrtPriceX96', type: 'uint160' },
      { name: 'tick',         type: 'int24'   },
      { name: 'protocolFee',  type: 'uint24'  },
      { name: 'lpFee',        type: 'uint24'  },
    ] },
] as const

export const PERMIT2_ABI = [
  { name: 'approve', type: 'function', stateMutability: 'nonpayable',
    inputs: [
      { name: 'token',      type: 'address' },
      { name: 'spender',    type: 'address' },
      { name: 'amount',     type: 'uint160' },
      { name: 'expiration', type: 'uint48'  },
    ],
    outputs: [] },
  { name: 'allowance', type: 'function', stateMutability: 'view',
    inputs: [
      { name: 'user',    type: 'address' },
      { name: 'token',   type: 'address' },
      { name: 'spender', type: 'address' },
    ],
    outputs: [
      { name: 'amount',     type: 'uint160' },
      { name: 'expiration', type: 'uint48'  },
      { name: 'nonce',      type: 'uint48'  },
    ] },
] as const

export const UNIVERSAL_ROUTER_ABI = [
  { name: 'execute', type: 'function', stateMutability: 'payable',
    inputs: [
      { name: 'commands', type: 'bytes'    },
      { name: 'inputs',   type: 'bytes[]'  },
      { name: 'deadline', type: 'uint256'  },
    ],
    outputs: [] },
] as const

// ── Encode helpers ────────────────────────────────────────────────────────────

// V4 action bytes
const ACTIONS = {
  SWAP_EXACT_IN_SINGLE: 0x06,
  SETTLE_PAIR:          0x0d,
  TAKE_PAIR:            0x11,
} as const

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const _encodeAbi = encodeAbiParameters as (...args: any[]) => `0x${string}`

export function buildPoolKey(q: QuestionState) {
  return {
    currency0:   q.currency0,
    currency1:   q.currency1,
    fee:         POOL_FEE,
    tickSpacing: TICK_SPACING,
    hooks:       ADDRESSES.HOOK,
  }
}

export function encodePoolId(q: QuestionState): `0x${string}` {
  const key = buildPoolKey(q)
  return keccak256(
    encodeAbiParameters(
      [
        { type: 'address' }, { type: 'address' },
        { type: 'uint24'  }, { type: 'int24'   },
        { type: 'address' },
      ],
      [key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks]
    )
  ) as `0x${string}`
}

// ABI-encode the full PoolKey struct — this is what ENCODED_KEY env var needs
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const _enc = encodeAbiParameters as (...args: any[]) => `0x${string}`
export function computeEncodedKey(q: QuestionState): `0x${string}` {
  return _enc(
    [{
      type: 'tuple',
      components: [
        { name: 'currency0',   type: 'address' },
        { name: 'currency1',   type: 'address' },
        { name: 'fee',         type: 'uint24'  },
        { name: 'tickSpacing', type: 'int24'   },
        { name: 'hooks',       type: 'address' },
      ],
    }],
    [[q.currency0, q.currency1, POOL_FEE, TICK_SPACING, ADDRESSES.HOOK]]
  )
}

// Encode ERC20.approve
export function encodeApprove(spender: `0x${string}`, amount: bigint): `0x${string}` {
  return encodeFunctionData({ abi: ERC20_ABI, functionName: 'approve', args: [spender, amount] })
}

// Encode Permit2.approve(token, spender, MAX_UINT160, MAX_UINT48)
export function encodePermit2Approve(token: `0x${string}`, spender: `0x${string}`): `0x${string}` {
  const MAX_UINT160 = (1n << 160n) - 1n
  const MAX_UINT48  = 281474976710655
  return encodeFunctionData({
    abi: PERMIT2_ABI,
    functionName: 'approve',
    args: [token, spender, MAX_UINT160, MAX_UINT48],
  })
}

// Encode CollateralVault.mint(amount)
export function encodeMint(amount: bigint): `0x${string}` {
  return encodeFunctionData({ abi: VAULT_ABI, functionName: 'mint', args: [amount] })
}

// Encode CollateralVault.burn(amount)
export function encodeBurn(amount: bigint): `0x${string}` {
  return encodeFunctionData({ abi: VAULT_ABI, functionName: 'burn', args: [amount] })
}

// Encode CollateralVault.redeem(amount)
export function encodeRedeem(amount: bigint): `0x${string}` {
  return encodeFunctionData({ abi: VAULT_ABI, functionName: 'redeem', args: [amount] })
}

// Encode QuestionFactory.create(targetPrice, expiry)
export function encodeCreate(targetPrice: bigint, expiry: bigint): `0x${string}` {
  return encodeFunctionData({ abi: FACTORY_ABI, functionName: 'create', args: [targetPrice, expiry] })
}

// Encode UniversalRouter V4 exact-input-single swap
export function encodeV4Swap(params: {
  currency0:   `0x${string}`
  currency1:   `0x${string}`
  zeroForOne:  boolean
  amountIn:    bigint
  recipient:   `0x${string}`
  deadline:    bigint
}): `0x${string}` {
  const actions = encodePacked(
    ['uint8', 'uint8', 'uint8'],
    [ACTIONS.SWAP_EXACT_IN_SINGLE, ACTIONS.SETTLE_PAIR, ACTIONS.TAKE_PAIR]
  )

  const poolKeyArr = [
    params.currency0, params.currency1,
    POOL_FEE, TICK_SPACING, ADDRESSES.HOOK,
  ]

  const swapParam = _encodeAbi(
    [{
      type: 'tuple',
      components: [
        POOL_KEY_TUPLE,
        { name: 'zeroForOne',       type: 'bool'    },
        { name: 'amountIn',         type: 'uint128' },
        { name: 'amountOutMinimum', type: 'uint128' },
        { name: 'hookData',         type: 'bytes'   },
      ],
    }],
    [[poolKeyArr, params.zeroForOne, params.amountIn, 0n, '0x']]
  )

  const settleParam = encodeAbiParameters(
    [{ type: 'address' }, { type: 'address' }],
    [params.currency0, params.currency1]
  )

  const takeParam = encodeAbiParameters(
    [{ type: 'address' }, { type: 'address' }, { type: 'address' }],
    [params.currency0, params.currency1, params.recipient]
  )

  const v4Input = encodeAbiParameters(
    [{ type: 'bytes' }, { type: 'bytes[]' }],
    [actions, [swapParam, settleParam, takeParam]]
  )

  return encodeFunctionData({
    abi: UNIVERSAL_ROUTER_ABI,
    functionName: 'execute',
    args: ['0x10', [v4Input], params.deadline],
  })
}

// ── Probability from sqrtPriceX96 ─────────────────────────────────────────────
// Returns YES probability as a percentage (0–100)
// currency0 is sorted lower address; YES may be currency0 or currency1
export function yesProb(sqrtPriceX96: bigint, yesCurrency: 'currency0' | 'currency1'): number {
  if (sqrtPriceX96 === 0n) return 50
  // price of token0 in token1 = (sqrtPriceX96 / 2^96)^2
  const Q96 = 2n ** 96n
  const numF  = Number(sqrtPriceX96)
  const denF  = Number(Q96)
  const price0in1 = (numF / denF) ** 2  // price of currency0 in currency1

  // In prediction market: P(YES) = price_YES / (price_YES + price_NO)
  // Since YES+NO are complementary and at 50/50 start price=1:
  // if YES is currency0: p = price0in1 = (YES price in NO) → P(YES) = p/(1+p)
  // if YES is currency1: p = 1/price0in1 = (YES price in NO) → P(YES) = p/(1+p)
  let yesPrice: number
  if (yesCurrency === 'currency0') {
    yesPrice = price0in1
  } else {
    yesPrice = price0in1 === 0 ? 0 : 1 / price0in1
  }

  return (yesPrice / (1 + yesPrice)) * 100
}

// ── MetaMask helpers ──────────────────────────────────────────────────────────

declare global {
  interface Window {
    ethereum?: {
      request: (args: { method: string; params?: unknown[] }) => Promise<unknown>
      on: (event: string, handler: (...args: unknown[]) => void) => void
      removeListener: (event: string, handler: (...args: unknown[]) => void) => void
      isMetaMask?: boolean
    }
  }
}

export async function getAccounts(): Promise<`0x${string}`[]> {
  if (!window.ethereum) throw new Error('MetaMask not found')
  return window.ethereum.request({ method: 'eth_requestAccounts' }) as Promise<`0x${string}`[]>
}

export async function switchChain(chainId: number): Promise<void> {
  const hex = '0x' + chainId.toString(16)
  try {
    await window.ethereum!.request({
      method: 'wallet_switchEthereumChain',
      params: [{ chainId: hex }],
    })
  } catch {
    // Chain not added — add it
    await window.ethereum!.request({
      method: 'wallet_addEthereumChain',
      params: [{
        chainId: hex,
        chainName: 'Unichain Sepolia',
        nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
        rpcUrls: ['https://sepolia.unichain.org'],
        blockExplorerUrls: ['https://unichain-sepolia.blockscout.com'],
      }],
    })
  }
}

export async function sendTx(
  to: `0x${string}`,
  data: `0x${string}`,
  from: `0x${string}`,
  value?: bigint,
  gas?: number,
): Promise<`0x${string}`> {
  return window.ethereum!.request({
    method: 'eth_sendTransaction',
    params: [{
      from,
      to,
      data,
      gas: '0x' + (gas ?? 600_000).toString(16),
      ...(value !== undefined ? { value: '0x' + value.toString(16) } : {}),
    }],
  }) as Promise<`0x${string}`>
}

export async function waitForTx(hash: `0x${string}`): Promise<void> {
  for (let i = 0; i < 90; i++) {
    await new Promise(r => setTimeout(r, 2000))
    try {
      const receipt = await window.ethereum!.request({
        method: 'eth_getTransactionReceipt',
        params: [hash],
      }) as { status: string } | null
      if (receipt) {
        if (receipt.status === '0x0') throw new Error('Transaction reverted on-chain (out of gas or revert)')
        return
      }
    } catch (err) {
      if (err instanceof Error && err.message.includes('reverted')) throw err
      /* continue polling on RPC errors */
    }
  }
  throw new Error('Transaction timeout after 180s')
}

export function blockscoutTx(hash: string): string {
  return `https://unichain-sepolia.blockscout.com/tx/${hash}`
}

export function fmt6(val: bigint): string {
  const s = val.toString().padStart(7, '0')
  const int = s.slice(0, -6) || '0'
  const dec = s.slice(-6).replace(/0+$/, '') || '0'
  return `${int}.${dec}`
}

export function fmtPrice8(val: bigint): string {
  // Chainlink 8-decimal price: e.g. 500000000000 = $5,000
  const s = val.toString().padStart(9, '0')
  const int = s.slice(0, -8) || '0'
  const dec = s.slice(-8).replace(/0+$/, '') || '0'
  return `$${Number(int).toLocaleString()}.${dec}`
}

export { parseUnits, maxUint256, encodeFunctionData, keccak256, encodeAbiParameters }
