// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";

interface ICollateralVault {
    function settle(bool yesWon) external;
}

/// @title OracleSettle Hook v2
/// @notice Uniswap v4 hook for a prediction market AMM with cross-chain settlement.
///
/// Architecture:
///   - Pool of YES/NO tokens: pure price discovery (pool price = implied probability).
///   - CollateralVault: holds USDC, mints YES+NO pairs 1:1, guarantees 1 USDC per winning token.
///   - QuestionFactory: deploys YES, NO, vault per question; initialises pool; calls initMarket().
///   - Reactive pipeline: monitors Chainlink oracle on origin chain; triggers settle() via callback.
///
/// Settlement:
///   Once settled ALL pool swaps are blocked. Winners redeem through vault.redeem(), not the pool.
contract OracleSettleHook is BaseHook {
    using PoolIdLibrary for PoolKey;

    // --- Enums ---

    enum Phase { TRADING, RESOLVED }

    // --- Structs ---

    struct MarketState {
        Phase   phase;
        bool    yesWon;           // valid only when phase == RESOLVED
        int256  targetPrice;      // e.g. 5000e8 for $5,000 in Chainlink 8-decimal format
        uint256 expiryTimestamp;
        int256  settledPrice;     // actual Chainlink price at settlement
        bool    initialized;
        address vault;            // CollateralVault; address(0) = no vault attached
    }

    // --- State ---

    address public owner;
    address public callbackContract;
    address public factory;

    /// @notice Market state keyed by pool ID
    mapping(PoolId => MarketState) public markets;

    // --- Events ---

    event MarketInitialized(PoolId indexed poolId, int256 targetPrice, uint256 expiry);
    event MarketSettled(PoolId indexed poolId, bool yesWon, int256 settledPrice);
    event CallbackContractSet(address indexed callback);
    event FactorySet(address indexed factory);

    // --- Errors ---

    error OnlyCallback();
    error OnlyOwner();
    error MarketAlreadySettled();
    error SwapBlockedAfterSettlement();
    error MarketNotInitialized();
    error CallbackAlreadySet();
    error ZeroAddress();

    // --- Modifiers ---

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    modifier onlyCallback() {
        if (msg.sender != callbackContract) revert OnlyCallback();
        _;
    }

    modifier onlyOwnerOrFactory() {
        if (msg.sender != owner && msg.sender != factory) revert OnlyOwner();
        _;
    }

    // --- Constructor ---

    constructor(IPoolManager _poolManager, address _owner) BaseHook(_poolManager) {
        owner = _owner != address(0) ? _owner : msg.sender;
    }

    // --- Hook Permissions ---

    /// @notice Returns the hook permission flags for the PoolManager
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // --- Hook Implementations ---

    /// @dev No-op: hook registration only; market setup is done via initMarket after initialization.
    function _beforeInitialize(address, PoolKey calldata, uint160) internal pure override returns (bytes4) {
        return this.beforeInitialize.selector;
    }

    /// @dev Blocks all swaps once the market is RESOLVED.
    ///   All post-settlement token redemption goes through CollateralVault.redeem(), not the pool.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (markets[key.toId()].phase == Phase.RESOLVED) revert SwapBlockedAfterSettlement();
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    // --- Admin Functions ---

    /// @notice Set the callback contract address. Can only be set once.
    /// @param _callback Address of OracleSettleCallback on Unichain
    function setCallbackContract(address _callback) external onlyOwner {
        if (_callback == address(0)) revert ZeroAddress();
        if (callbackContract != address(0)) revert CallbackAlreadySet();
        callbackContract = _callback;
        emit CallbackContractSet(_callback);
    }

    /// @notice Set the QuestionFactory address. Factory can call initMarket.
    function setFactory(address _factory) external onlyOwner {
        factory = _factory;
        emit FactorySet(_factory);
    }

    // --- Market Management ---

    /// @notice Configure the prediction question for a pool. Must be called after pool initialisation.
    ///   Callable by owner or factory.
    /// @param key          The Uniswap v4 pool key for the prediction market
    /// @param targetPrice  Target price in Chainlink 8-decimal format (e.g. 5000e8 for $5,000)
    /// @param expiry       Unix timestamp after which oracle can trigger settlement
    /// @param vault        CollateralVault address; address(0) if no vault is attached
    function initMarket(PoolKey calldata key, int256 targetPrice, uint256 expiry, address vault)
        external
        onlyOwnerOrFactory
    {
        PoolId id = key.toId();
        markets[id] = MarketState({
            phase:           Phase.TRADING,
            yesWon:          false,
            targetPrice:     targetPrice,
            expiryTimestamp: expiry,
            settledPrice:    0,
            initialized:     true,
            vault:           vault
        });
        emit MarketInitialized(id, targetPrice, expiry);
    }

    /// @notice Called by the callback contract to settle the market with oracle outcome.
    ///   Propagates the outcome to the CollateralVault if one is attached.
    /// @param key           The pool key to settle
    /// @param _yesWon       True if YES outcome (price >= targetPrice at expiry)
    /// @param _settledPrice The actual Chainlink price at settlement time
    function settle(PoolKey calldata key, bool _yesWon, int256 _settledPrice) external onlyCallback {
        PoolId id = key.toId();
        MarketState storage market = markets[id];
        if (market.phase != Phase.TRADING) revert MarketAlreadySettled();
        market.phase       = Phase.RESOLVED;
        market.yesWon      = _yesWon;
        market.settledPrice = _settledPrice;
        emit MarketSettled(id, _yesWon, _settledPrice);

        // Propagate to CollateralVault so winners can redeem USDC 1:1
        if (market.vault != address(0)) {
            ICollateralVault(market.vault).settle(_yesWon);
        }
    }

    // --- View Functions ---

    /// @notice Returns the full market state for a given pool
    function getMarketState(PoolKey calldata key) external view returns (MarketState memory) {
        return markets[key.toId()];
    }
}
