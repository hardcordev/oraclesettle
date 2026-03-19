// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AbstractCallback} from "reactive-lib/AbstractCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

interface IOracleSettleHook {
    function settle(PoolKey calldata key, bool yesWon, int256 settledPrice) external;
}

/// @title OracleSettle Callback
/// @notice Deployed on Unichain. Receives Reactive Network callbacks and relays
/// the settlement outcome to OracleSettleHook.
contract OracleSettleCallback is AbstractCallback {
    IOracleSettleHook public immutable hook;

    event MarketSettledRelayed(bool yesWon, int256 settledPrice);

    constructor(address _callbackProxy, address _hook) AbstractCallback(_callbackProxy) {
        hook = IOracleSettleHook(_hook);
    }

    /// @notice Called by the Reactive Network to settle the prediction market.
    /// @param _rvm_id      The Reactive VM identifier (injected by Reactive Network; checked by rvmIdOnly)
    /// @param encodedKey   ABI-encoded PoolKey identifying the prediction pool
    /// @param yesWon       True if YES outcome (price >= targetPrice at expiry)
    /// @param settledPrice The actual Chainlink price at settlement
    function resolveMarket(
        address _rvm_id,
        bytes calldata encodedKey,
        bool yesWon,
        int256 settledPrice
    ) external rvmIdOnly(_rvm_id) {
        PoolKey memory key = abi.decode(encodedKey, (PoolKey));
        hook.settle(key, yesWon, settledPrice);
        emit MarketSettledRelayed(yesWon, settledPrice);
    }
}
