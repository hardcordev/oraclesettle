// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AbstractReactive} from "reactive-lib/AbstractReactive.sol";

/// @title OracleSettle Reactive Smart Contract
/// @notice Deployed on Reactive Network (Lasna). Monitors a Chainlink price feed on Ethereum
/// for the AnswerUpdated event. Once the feed reports a price at or after the expiry timestamp,
/// computes the YES/NO outcome and emits a cross-chain callback to OracleSettleCallback on Unichain,
/// which then calls OracleSettleHook.settle() to lock the prediction market.
///
/// Chainlink AnswerUpdated event (AggregatorV3):
///   event AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 updatedAt)
///   topic_0 = keccak256("AnswerUpdated(int256,uint256,uint256)")
///   topic_1 = current  (int256 price, indexed)
///   topic_2 = roundId  (uint256, indexed)
///   data    = abi.encode(updatedAt)  (uint256, non-indexed)
contract OracleSettleReactive is AbstractReactive {
    // --- Constants ---

    uint64 public constant CALLBACK_GAS_LIMIT = 300_000;

    /// @notice keccak256("AnswerUpdated(int256,uint256,uint256)")
    uint256 public constant ANSWER_UPDATED_TOPIC0 =
        0x0559884fd3a460db3073b7fc896cc77986f16e378210ded43186175bf646fc5f;

    // --- Immutables ---

    uint256 public immutable ORIGIN_CHAIN_ID;
    uint256 public immutable DEST_CHAIN_ID;

    address public immutable chainlinkFeed;
    address public immutable callbackContract;
    bytes   public encodedKey;
    int256  public immutable targetPrice;
    uint256 public immutable expiryTimestamp;

    // --- State ---

    bool public settled;

    // --- Events ---

    event SettlementTriggered(bool yesWon, int256 settledPrice, uint256 updatedAt);

    // --- Constructor ---

    /// @param _chainlinkFeed     Chainlink price feed on origin chain (e.g. ETH/USD Sepolia)
    /// @param _callbackContract  OracleSettleCallback address on Unichain
    /// @param _encodedKey        ABI-encoded PoolKey for the prediction pool
    /// @param _targetPrice       Target price in Chainlink 8-decimal format (e.g. 5000e8)
    /// @param _expiryTimestamp   Unix timestamp of market expiry
    /// @param _originChainId     Chain ID of the origin chain (1 = mainnet, 11155111 = Sepolia)
    /// @param _destChainId       Chain ID of Unichain (1301 = Sepolia)
    constructor(
        address _chainlinkFeed,
        address _callbackContract,
        bytes memory _encodedKey,
        int256 _targetPrice,
        uint256 _expiryTimestamp,
        uint256 _originChainId,
        uint256 _destChainId
    ) payable {
        chainlinkFeed    = _chainlinkFeed;
        callbackContract = _callbackContract;
        encodedKey       = _encodedKey;
        targetPrice      = _targetPrice;
        expiryTimestamp  = _expiryTimestamp;
        ORIGIN_CHAIN_ID  = _originChainId;
        DEST_CHAIN_ID    = _destChainId;

        // Subscribe to Chainlink AnswerUpdated on origin chain (skipped in Reactive VM)
        if (!vm) {
            service.subscribe(
                _originChainId,
                _chainlinkFeed,
                ANSWER_UPDATED_TOPIC0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
        }
    }

    // --- React ---

    /// @notice Entry point for Reactive Network log notifications
    function react(LogRecord calldata log) external vmOnly {
        // Filter: must be AnswerUpdated from the correct feed on the correct chain
        if (log.topic_0 != ANSWER_UPDATED_TOPIC0) return;
        if (log._contract != chainlinkFeed) return;
        if (log.chain_id != ORIGIN_CHAIN_ID) return;

        // Prevent double-settlement
        if (settled) return;

        // Decode updatedAt from non-indexed data (first 32 bytes)
        uint256 updatedAt = abi.decode(log.data, (uint256));

        // Only settle after expiry
        if (updatedAt < expiryTimestamp) return;

        // Read price from topic_1 (indexed int256 stored as uint256)
        int256 current = int256(log.topic_1);

        // Determine outcome: YES wins if price >= targetPrice
        bool yesWon = (current >= targetPrice);

        // Mark settled to prevent re-entry
        settled = true;

        emit SettlementTriggered(yesWon, current, updatedAt);

        // Emit cross-chain callback to Unichain
        bytes memory payload = abi.encodeWithSignature(
            "resolveMarket(address,bytes,bool,int256)",
            address(0), // replaced by Reactive Network with actual RVM ID
            encodedKey,
            yesWon,
            current
        );
        emit Callback(DEST_CHAIN_ID, callbackContract, CALLBACK_GAS_LIMIT, payload);
    }
}
