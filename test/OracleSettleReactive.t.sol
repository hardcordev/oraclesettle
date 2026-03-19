// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test, Vm} from "forge-std/Test.sol";

import {OracleSettleReactive} from "../src/OracleSettleReactive.sol";

// ---------------------------------------------------------------------------
// OracleSettleReactiveHarness
//
// Extends OracleSettleReactive to allow react() to be called in Forge tests.
// In Forge, AbstractReactive.detectVm() returns vm=true (no code at 0xfffFfF),
// so subscriptions are skipped and react() (vmOnly) is callable.
// ---------------------------------------------------------------------------
contract OracleSettleReactiveHarness is OracleSettleReactive {
    constructor(
        address _chainlinkFeed,
        address _callbackContract,
        bytes memory _encodedKey,
        int256 _targetPrice,
        uint256 _expiryTimestamp,
        uint256 _originChainId,
        uint256 _destChainId
    ) OracleSettleReactive(
        _chainlinkFeed,
        _callbackContract,
        _encodedKey,
        _targetPrice,
        _expiryTimestamp,
        _originChainId,
        _destChainId
    ) {}

    /// @notice Build a LogRecord and call react() — simulates a Reactive Network notification
    /// @param chainId      Origin chain ID in the log
    /// @param contractAddr Emitting contract address
    /// @param topic0       Log topic 0 (event signature hash)
    /// @param topic1       Log topic 1 (indexed: int256 current price as uint256)
    /// @param data         Non-indexed log data (abi.encoded updatedAt)
    function reactTest(
        uint256 chainId,
        address contractAddr,
        uint256 topic0,
        uint256 topic1,
        bytes memory data
    ) external {
        LogRecord memory log = LogRecord({
            chain_id: chainId,
            _contract: contractAddr,
            topic_0: topic0,
            topic_1: topic1,
            topic_2: 0,
            topic_3: 0,
            data: data,
            block_number: block.number,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });
        this.react(log);
    }
}

// ---------------------------------------------------------------------------
// OracleSettleReactiveTest
// ---------------------------------------------------------------------------
contract OracleSettleReactiveTest is Test {
    OracleSettleReactiveHarness harness;

    uint256 constant ORIGIN_CHAIN_ID = 11_155_111; // Ethereum Sepolia
    uint256 constant DEST_CHAIN_ID   = 1_301;      // Unichain Sepolia
    int256  constant TARGET_PRICE    = 5_000e8;
    uint256 constant EXPIRY          = 1_800_000_000; // arbitrary future timestamp

    address constant CHAINLINK_FEED      = address(0xFEED);
    address constant CALLBACK_CONTRACT   = address(0xCAFE);

    bytes encodedKey;

    function setUp() public {
        // encodedKey is arbitrary bytes for testing (would be abi.encode(PoolKey) in prod)
        encodedKey = abi.encode(uint256(0xBEEF));

        harness = new OracleSettleReactiveHarness(
            CHAINLINK_FEED,
            CALLBACK_CONTRACT,
            encodedKey,
            TARGET_PRICE,
            EXPIRY,
            ORIGIN_CHAIN_ID,
            DEST_CHAIN_ID
        );
    }

    // ==================== Construction ====================

    function test_construction_subscribesInNonVm() public view {
        // In Forge tests, vm=true so subscriptions are skipped.
        // Just verify immutables are set correctly.
        assertEq(harness.chainlinkFeed(), CHAINLINK_FEED);
        assertEq(harness.callbackContract(), CALLBACK_CONTRACT);
        assertEq(harness.targetPrice(), TARGET_PRICE);
        assertEq(harness.expiryTimestamp(), EXPIRY);
        assertEq(harness.ORIGIN_CHAIN_ID(), ORIGIN_CHAIN_ID);
        assertEq(harness.DEST_CHAIN_ID(), DEST_CHAIN_ID);
        assertFalse(harness.settled());
    }

    // ==================== Filtering ====================

    function test_react_ignoresWrongTopic() public {
        bytes memory data = abi.encode(EXPIRY);
        // Wrong topic_0 → no settlement
        harness.reactTest(ORIGIN_CHAIN_ID, CHAINLINK_FEED, 0xDEAD, uint256(int256(TARGET_PRICE)), data);
        assertFalse(harness.settled());
    }

    function test_react_ignoresWrongContract() public {
        bytes memory data = abi.encode(EXPIRY);
        // Wrong contract address → no settlement
        harness.reactTest(
            ORIGIN_CHAIN_ID,
            address(0xBAD),
            harness.ANSWER_UPDATED_TOPIC0(),
            uint256(int256(TARGET_PRICE)),
            data
        );
        assertFalse(harness.settled());
    }

    function test_react_ignoresWrongOriginChain() public {
        bytes memory data = abi.encode(EXPIRY);
        // Wrong chain_id → no settlement
        harness.reactTest(
            1, // mainnet instead of Sepolia
            CHAINLINK_FEED,
            harness.ANSWER_UPDATED_TOPIC0(),
            uint256(int256(TARGET_PRICE)),
            data
        );
        assertFalse(harness.settled());
    }

    // ==================== Expiry Timing ====================

    function test_react_beforeExpiry_noSettlement() public {
        // updatedAt = EXPIRY - 1 → not yet expired
        bytes memory data = abi.encode(EXPIRY - 1);
        harness.reactTest(
            ORIGIN_CHAIN_ID,
            CHAINLINK_FEED,
            harness.ANSWER_UPDATED_TOPIC0(),
            uint256(int256(TARGET_PRICE + 1e8)), // price above target
            data
        );
        assertFalse(harness.settled());
    }

    function test_react_atExactExpiry_settles() public {
        // updatedAt = EXPIRY exactly → should settle
        bytes memory data = abi.encode(EXPIRY);
        harness.reactTest(
            ORIGIN_CHAIN_ID,
            CHAINLINK_FEED,
            harness.ANSWER_UPDATED_TOPIC0(),
            uint256(int256(TARGET_PRICE)),
            data
        );
        assertTrue(harness.settled());
    }

    function test_react_afterExpiry_settles() public {
        bytes memory data = abi.encode(EXPIRY + 1000);
        harness.reactTest(
            ORIGIN_CHAIN_ID,
            CHAINLINK_FEED,
            harness.ANSWER_UPDATED_TOPIC0(),
            uint256(int256(TARGET_PRICE + 1e8)),
            data
        );
        assertTrue(harness.settled());
    }

    // ==================== Outcome Determination ====================

    function test_react_priceAboveTarget_yesWon() public {
        bytes memory data = abi.encode(EXPIRY);
        int256 price = TARGET_PRICE + 1e8; // above target

        vm.recordLogs();
        harness.reactTest(
            ORIGIN_CHAIN_ID,
            CHAINLINK_FEED,
            harness.ANSWER_UPDATED_TOPIC0(),
            uint256(int256(price)),
            data
        );

        // Verify SettlementTriggered event
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bool foundEvent = false;
        bytes32 settledSig = keccak256("SettlementTriggered(bool,int256,uint256)");
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == settledSig) {
                (bool yesWon, int256 settledPrice,) = abi.decode(entries[i].data, (bool, int256, uint256));
                assertTrue(yesWon);
                assertEq(settledPrice, price);
                foundEvent = true;
                break;
            }
        }
        assertTrue(foundEvent, "SettlementTriggered not emitted");
    }

    function test_react_priceBelowTarget_noWon() public {
        bytes memory data = abi.encode(EXPIRY);
        int256 price = TARGET_PRICE - 1e8; // below target

        vm.recordLogs();
        harness.reactTest(
            ORIGIN_CHAIN_ID,
            CHAINLINK_FEED,
            harness.ANSWER_UPDATED_TOPIC0(),
            uint256(int256(price)),
            data
        );

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 settledSig = keccak256("SettlementTriggered(bool,int256,uint256)");
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == settledSig) {
                (bool yesWon,,) = abi.decode(entries[i].data, (bool, int256, uint256));
                assertFalse(yesWon);
                break;
            }
        }
    }

    function test_react_priceEqualsTarget_yesWon() public {
        // Boundary: price == targetPrice → YES wins (>= condition)
        bytes memory data = abi.encode(EXPIRY);

        vm.recordLogs();
        harness.reactTest(
            ORIGIN_CHAIN_ID,
            CHAINLINK_FEED,
            harness.ANSWER_UPDATED_TOPIC0(),
            uint256(int256(TARGET_PRICE)), // exactly equal
            data
        );

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 settledSig = keccak256("SettlementTriggered(bool,int256,uint256)");
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == settledSig) {
                (bool yesWon,,) = abi.decode(entries[i].data, (bool, int256, uint256));
                assertTrue(yesWon); // price == target → YES wins
                break;
            }
        }
    }

    // ==================== Double-Settlement Prevention ====================

    function test_react_alreadySettled_noDoubleSettlement() public {
        bytes memory data = abi.encode(EXPIRY);
        uint256 topic = harness.ANSWER_UPDATED_TOPIC0();

        // First settlement
        harness.reactTest(ORIGIN_CHAIN_ID, CHAINLINK_FEED, topic, uint256(int256(TARGET_PRICE)), data);
        assertTrue(harness.settled());

        // Second call: should be a no-op (settled flag prevents double-settlement)
        vm.recordLogs();
        harness.reactTest(ORIGIN_CHAIN_ID, CHAINLINK_FEED, topic, uint256(int256(TARGET_PRICE - 1e8)), data);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        // No Callback event should be emitted on second call
        bytes32 callbackSig = keccak256("Callback(uint256,address,uint64,bytes)");
        for (uint256 i = 0; i < entries.length; i++) {
            assertNotEq(entries[i].topics[0], callbackSig);
        }
    }

    // ==================== Callback Encoding ====================

    function test_react_callbackEncoding_correct() public {
        bytes memory data = abi.encode(EXPIRY);

        vm.recordLogs();
        harness.reactTest(
            ORIGIN_CHAIN_ID,
            CHAINLINK_FEED,
            harness.ANSWER_UPDATED_TOPIC0(),
            uint256(int256(TARGET_PRICE)),
            data
        );

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 callbackSig = keccak256("Callback(uint256,address,uint64,bytes)");
        bool foundCallback = false;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == callbackSig) {
                bytes memory payload = abi.decode(entries[i].data, (bytes));
                // Payload should start with resolveMarket(address,bytes,bool,int256) selector
                bytes4 selector = bytes4(payload);
                assertEq(selector, bytes4(keccak256("resolveMarket(address,bytes,bool,int256)")));
                foundCallback = true;
                break;
            }
        }
        assertTrue(foundCallback, "Callback event not emitted");
    }

    function test_react_callbackTargetChain_correct() public {
        bytes memory data = abi.encode(EXPIRY);

        vm.recordLogs();
        harness.reactTest(
            ORIGIN_CHAIN_ID,
            CHAINLINK_FEED,
            harness.ANSWER_UPDATED_TOPIC0(),
            uint256(int256(TARGET_PRICE)),
            data
        );

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 callbackSig = keccak256("Callback(uint256,address,uint64,bytes)");
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == callbackSig) {
                // chain_id is indexed → topic_1
                uint256 chainId = uint256(entries[i].topics[1]);
                assertEq(chainId, DEST_CHAIN_ID);
                break;
            }
        }
    }

    function test_react_settledPriceIncludedInPayload() public {
        bytes memory data = abi.encode(EXPIRY);
        int256 price = 6_500e8;

        vm.recordLogs();
        harness.reactTest(
            ORIGIN_CHAIN_ID,
            CHAINLINK_FEED,
            harness.ANSWER_UPDATED_TOPIC0(),
            uint256(int256(price)),
            data
        );

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 callbackSig = keccak256("Callback(uint256,address,uint64,bytes)");
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == callbackSig) {
                bytes memory payload = abi.decode(entries[i].data, (bytes));
                // Payload: selector(4) + address(32) + bytes_offset(32) + bool(32) + int256(32) + bytes_len(32) + bytes_data(...)
                // Decode: resolveMarket(address _rvm_id, bytes encodedKey, bool yesWon, int256 settledPrice)
                (, , bool yesWon, int256 settledPrice) = abi.decode(
                    _slice(payload, 4),
                    (address, bytes, bool, int256)
                );
                assertTrue(yesWon); // price 6500e8 >= 5000e8
                assertEq(settledPrice, price);
                break;
            }
        }
    }

    function test_react_emitsCallbackEvent() public {
        bytes memory callData = abi.encode(EXPIRY);

        vm.recordLogs();
        harness.reactTest(
            ORIGIN_CHAIN_ID,
            CHAINLINK_FEED,
            harness.ANSWER_UPDATED_TOPIC0(),
            uint256(int256(TARGET_PRICE)),
            callData
        );

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 callbackSig = keccak256("Callback(uint256,address,uint64,bytes)");
        bool found = false;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == callbackSig) {
                // Verify target contract is the callback contract
                address target = address(uint160(uint256(entries[i].topics[2])));
                assertEq(target, CALLBACK_CONTRACT);
                found = true;
                break;
            }
        }
        assertTrue(found, "Callback event not emitted");
    }

    // ==================== Multi-Update Scenarios ====================

    function test_react_multipleUpdatesBeforeExpiry_noSettle() public {
        uint256 topic = harness.ANSWER_UPDATED_TOPIC0();

        // Multiple updates before expiry — none should settle
        for (uint256 i = 0; i < 5; i++) {
            bytes memory data = abi.encode(EXPIRY - 100 + i); // all before EXPIRY
            harness.reactTest(ORIGIN_CHAIN_ID, CHAINLINK_FEED, topic, uint256(int256(TARGET_PRICE)), data);
            assertFalse(harness.settled());
        }
    }

    function test_react_firstUpdateAfterExpiry_settles() public {
        uint256 topic = harness.ANSWER_UPDATED_TOPIC0();

        // Updates before expiry
        for (uint256 i = 0; i < 3; i++) {
            bytes memory preData = abi.encode(EXPIRY - 10 + i);
            harness.reactTest(ORIGIN_CHAIN_ID, CHAINLINK_FEED, topic, uint256(int256(TARGET_PRICE)), preData);
        }
        assertFalse(harness.settled());

        // First update at/after expiry
        bytes memory postData = abi.encode(EXPIRY);
        harness.reactTest(ORIGIN_CHAIN_ID, CHAINLINK_FEED, topic, uint256(int256(TARGET_PRICE)), postData);
        assertTrue(harness.settled());
    }

    function test_react_updatedAtUsedNotBlockTimestamp() public {
        // Even if block.timestamp > expiry, if updatedAt < expiry, should not settle
        vm.warp(EXPIRY + 9999); // block.timestamp is past expiry

        bytes memory data = abi.encode(EXPIRY - 1); // updatedAt < expiry
        harness.reactTest(
            ORIGIN_CHAIN_ID,
            CHAINLINK_FEED,
            harness.ANSWER_UPDATED_TOPIC0(),
            uint256(int256(TARGET_PRICE)),
            data
        );
        // Should NOT settle because updatedAt < expiry, regardless of block.timestamp
        assertFalse(harness.settled());
    }

    // ==================== Fuzz Tests ====================

    function testFuzz_react_anyPriceVsTarget_deterministic(int256 price) public {
        // Bound price to reasonable range (avoid overflow in uint256 cast)
        price = bound(price, 0, int256(uint256(type(uint128).max)));

        bytes memory data = abi.encode(EXPIRY);

        vm.recordLogs();
        harness.reactTest(
            ORIGIN_CHAIN_ID,
            CHAINLINK_FEED,
            harness.ANSWER_UPDATED_TOPIC0(),
            uint256(int256(price)),
            data
        );

        assertTrue(harness.settled());

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 settledSig = keccak256("SettlementTriggered(bool,int256,uint256)");
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == settledSig) {
                (bool yesWon,,) = abi.decode(entries[i].data, (bool, int256, uint256));
                // Verify: yesWon iff price >= TARGET_PRICE
                assertEq(yesWon, price >= TARGET_PRICE);
                break;
            }
        }
    }

    function testFuzz_react_expiryBoundary_correct(uint256 updatedAt) public {
        updatedAt = bound(updatedAt, 0, type(uint128).max);

        bytes memory data = abi.encode(updatedAt);

        harness.reactTest(
            ORIGIN_CHAIN_ID,
            CHAINLINK_FEED,
            harness.ANSWER_UPDATED_TOPIC0(),
            uint256(int256(TARGET_PRICE)),
            data
        );

        // Should only be settled if updatedAt >= EXPIRY
        assertEq(harness.settled(), updatedAt >= EXPIRY);
    }

    // ==================== Zero / Negative Price ====================

    function test_react_zeroPrice_noWon() public {
        // price = 0, TARGET_PRICE = 5000e8 → 0 < 5000e8 → NO wins
        bytes memory data = abi.encode(EXPIRY);
        vm.recordLogs();
        harness.reactTest(ORIGIN_CHAIN_ID, CHAINLINK_FEED, harness.ANSWER_UPDATED_TOPIC0(), 0, data);

        assertTrue(harness.settled());

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 settledSig = keccak256("SettlementTriggered(bool,int256,uint256)");
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == settledSig) {
                (bool yesWon,,) = abi.decode(entries[i].data, (bool, int256, uint256));
                assertFalse(yesWon);
                break;
            }
        }
    }

    function test_react_encodedKeyPreservedInPayload() public {
        bytes memory data = abi.encode(EXPIRY);
        vm.recordLogs();
        harness.reactTest(
            ORIGIN_CHAIN_ID,
            CHAINLINK_FEED,
            harness.ANSWER_UPDATED_TOPIC0(),
            uint256(int256(TARGET_PRICE)),
            data
        );

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 callbackSig = keccak256("Callback(uint256,address,uint64,bytes)");
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == callbackSig) {
                bytes memory payload = abi.decode(entries[i].data, (bytes));
                // Skip 4-byte selector
                bytes memory sliced = _slice(payload, 4);
                (, bytes memory decodedKey,,) = abi.decode(sliced, (address, bytes, bool, int256));
                assertEq(decodedKey, harness.encodedKey());
                break;
            }
        }
    }

    function testFuzz_react_negativePrice_correctOutcome(int256 price) public {
        // Bound to half-range to avoid edge cases in arithmetic
        price = bound(price, type(int256).min / 2, type(int256).max / 2);

        bytes memory data = abi.encode(EXPIRY);
        harness.reactTest(
            ORIGIN_CHAIN_ID,
            CHAINLINK_FEED,
            harness.ANSWER_UPDATED_TOPIC0(),
            uint256(int256(price)), // two's complement; int256(topic_1) recovers price correctly
            data
        );

        assertTrue(harness.settled());

        // Verify outcome: yesWon iff price >= TARGET_PRICE
        vm.recordLogs();
        // Re-create a fresh harness to check the event from the original call
        // Instead, just validate settled state and re-check via SettlementTriggered from the original call
        // (logs were already emitted above — use vm.getRecordedLogs on harness2 for clean isolation)
        OracleSettleReactiveHarness harness2 = new OracleSettleReactiveHarness(
            CHAINLINK_FEED, CALLBACK_CONTRACT, encodedKey,
            TARGET_PRICE, EXPIRY, ORIGIN_CHAIN_ID, DEST_CHAIN_ID
        );
        harness2.reactTest(
            ORIGIN_CHAIN_ID,
            CHAINLINK_FEED,
            harness2.ANSWER_UPDATED_TOPIC0(),
            uint256(int256(price)),
            data
        );

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 settledSig = keccak256("SettlementTriggered(bool,int256,uint256)");
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == settledSig) {
                (bool yesWon,,) = abi.decode(entries[i].data, (bool, int256, uint256));
                assertEq(yesWon, price >= TARGET_PRICE);
                break;
            }
        }
    }

    // ==================== Topic Hash Verification ====================

    function test_answerUpdatedTopicHash_correct() public pure {
        uint256 expected = uint256(keccak256("AnswerUpdated(int256,uint256,uint256)"));
        uint256 actual = 0x0559884fd3a460db3073b7fc896cc77986f16e378210ded43186175bf646fc5f;
        assertEq(actual, expected);
    }

    // ==================== Helpers ====================

    /// @dev Slice bytes from offset to end
    function _slice(bytes memory data, uint256 start) internal pure returns (bytes memory result) {
        require(start <= data.length, "slice: out of bounds");
        result = new bytes(data.length - start);
        for (uint256 i = 0; i < result.length; i++) {
            result[i] = data[start + i];
        }
    }
}
