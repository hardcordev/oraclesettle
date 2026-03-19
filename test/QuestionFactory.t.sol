// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test, Vm} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";

import {OracleSettleHook} from "../src/OracleSettleHook.sol";
import {QuestionFactory} from "../src/QuestionFactory.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {OutcomeToken} from "../src/OutcomeToken.sol";

/// @dev Exercises QuestionFactory.create(): contract deployment, pool setup,
///      hook market registration, and question state management.
contract QuestionFactoryTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    OracleSettleHook hook;
    QuestionFactory  factory;
    MockERC20        usdc;

    address constant CALLBACK_ADDR = address(0xCA11);
    int256  constant TARGET_PRICE  = 5_000e8;
    uint256 expiry;

    function setUp() public {
        deployFreshManagerAndRouters();

        // Deploy hook at flag-encoded address
        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);
        deployCodeTo(
            "OracleSettleHook.sol:OracleSettleHook",
            abi.encode(manager, address(this)),
            address(flags)
        );
        hook = OracleSettleHook(address(flags));
        hook.setCallbackContract(CALLBACK_ADDR);

        usdc    = new MockERC20("Mock USDC", "USDC", 6);
        factory = new QuestionFactory(address(manager), address(usdc), address(hook));
        hook.setFactory(address(factory));

        expiry = block.timestamp + 7 days;
    }

    // ==================== Helpers ====================

    /// Calls factory.create() and returns the decoded PoolKey alongside the raw returns.
    function _create(int256 price, uint256 exp)
        internal
        returns (uint256 qId, address vault, PoolKey memory pk)
    {
        bytes memory encodedKey;
        (qId, vault, encodedKey) = factory.create(price, exp);
        pk = abi.decode(encodedKey, (PoolKey));
    }

    // ==================== create(): contract deployment ====================

    function test_create_deploysYesNoVaultContracts() public {
        (uint256 qId, address vault,) = _create(TARGET_PRICE, expiry);
        (address qVault, address qYes, address qNo,) = factory.questions(qId);

        assertNotEq(qVault, address(0));
        assertNotEq(qYes,   address(0));
        assertNotEq(qNo,    address(0));
        assertEq(qVault, vault);
    }

    function test_create_setsVaultOnYesToken() public {
        (, address vault,) = _create(TARGET_PRICE, expiry);
        (, address qYes,,) = factory.questions(0);
        assertEq(OutcomeToken(qYes).vault(), vault);
    }

    function test_create_setsVaultOnNoToken() public {
        (, address vault,) = _create(TARGET_PRICE, expiry);
        (,, address qNo,) = factory.questions(0);
        assertEq(OutcomeToken(qNo).vault(), vault);
    }

    function test_create_vaultHasCorrectUsdc() public {
        (, address vault,) = _create(TARGET_PRICE, expiry);
        assertEq(address(CollateralVault(vault).usdc()), address(usdc));
    }

    function test_create_vaultHasCorrectHook() public {
        (, address vault,) = _create(TARGET_PRICE, expiry);
        assertEq(CollateralVault(vault).hook(), address(hook));
    }

    function test_create_yesAndNoAreDifferentContracts() public {
        (, address vault,) = _create(TARGET_PRICE, expiry);
        (, address qYes, address qNo,) = factory.questions(0);
        assertNotEq(qYes, qNo);
        assertNotEq(qYes, vault);
        assertNotEq(qNo,  vault);
    }

    // ==================== create(): pool key ====================

    function test_create_poolKeyHasSortedCurrencies() public {
        (,, PoolKey memory pk) = _create(TARGET_PRICE, expiry);
        assertTrue(Currency.unwrap(pk.currency0) < Currency.unwrap(pk.currency1));
    }

    function test_create_poolKeyUsesFactoryConstants() public {
        (,, PoolKey memory pk) = _create(TARGET_PRICE, expiry);
        assertEq(pk.fee,            uint24(factory.POOL_FEE()));
        assertEq(pk.tickSpacing,    factory.TICK_SPACING());
        assertEq(address(pk.hooks), address(hook));
    }

    function test_create_poolCurrenciesAreYesAndNo() public {
        (,, PoolKey memory pk) = _create(TARGET_PRICE, expiry);
        (, address qYes, address qNo,) = factory.questions(0);
        address c0 = Currency.unwrap(pk.currency0);
        address c1 = Currency.unwrap(pk.currency1);
        assertTrue(
            (c0 == qYes && c1 == qNo) || (c0 == qNo && c1 == qYes),
            "Pool currencies must be YES and NO tokens"
        );
    }

    function test_create_encodedKeyDecodesToMatchingPoolKey() public {
        (uint256 qId,, PoolKey memory pk) = _create(TARGET_PRICE, expiry);
        (,,, bytes32 storedPid) = factory.questions(qId);
        // The stored poolId is keccak256(abi.encode(poolKey))
        bytes memory reEncoded = abi.encode(pk);
        assertEq(keccak256(reEncoded), storedPid);
    }

    // ==================== create(): hook market registration ====================

    function test_create_registersMarketAsTrading() public {
        (,, PoolKey memory pk) = _create(TARGET_PRICE, expiry);
        OracleSettleHook.MarketState memory state = hook.getMarketState(pk);
        assertTrue(state.initialized);
        assertEq(uint256(state.phase), uint256(OracleSettleHook.Phase.TRADING));
    }

    function test_create_registersCorrectTargetPriceAndExpiry() public {
        (,, PoolKey memory pk) = _create(TARGET_PRICE, expiry);
        OracleSettleHook.MarketState memory state = hook.getMarketState(pk);
        assertEq(state.targetPrice,     TARGET_PRICE);
        assertEq(state.expiryTimestamp, expiry);
    }

    function test_create_storesVaultInMarketState() public {
        (, address vault, PoolKey memory pk) = _create(TARGET_PRICE, expiry);
        assertEq(hook.getMarketState(pk).vault, vault);
    }

    // ==================== create(): question state ====================

    function test_create_startsAtQuestionId_zero() public {
        (uint256 qId,,) = _create(TARGET_PRICE, expiry);
        assertEq(qId, 0);
    }

    function test_create_incrementsQuestionCount() public {
        assertEq(factory.questionCount(), 0);
        _create(TARGET_PRICE, expiry);
        assertEq(factory.questionCount(), 1);
        _create(TARGET_PRICE, expiry + 1 days);
        assertEq(factory.questionCount(), 2);
    }

    function test_create_storesQuestionByIndex() public {
        (, address vault,) = _create(TARGET_PRICE, expiry);
        (address qVault,,,) = factory.questions(0);
        assertEq(qVault, vault);
    }

    // ==================== create(): events ====================

    function test_create_emitsQuestionCreated() public {
        vm.recordLogs();
        _create(TARGET_PRICE, expiry);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 sig = keccak256("QuestionCreated(uint256,address,address,address,bytes32)");
        bool found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) { found = true; break; }
        }
        assertTrue(found, "QuestionCreated event not emitted");
    }

    // ==================== create(): multiple questions ====================

    function test_create_multipleQuestions_independentAddresses() public {
        (,, PoolKey memory pk1) = _create(TARGET_PRICE, expiry);
        (,, PoolKey memory pk2) = _create(TARGET_PRICE, expiry + 1 days);

        (, address qYes1, address qNo1,) = factory.questions(0);
        (, address qYes2, address qNo2,) = factory.questions(1);

        assertNotEq(qYes1, qYes2);
        assertNotEq(qNo1,  qNo2);
        assertTrue(PoolId.unwrap(pk1.toId()) != PoolId.unwrap(pk2.toId()));
    }

    function test_create_multipleQuestions_settleIndependently() public {
        (, address vault1, PoolKey memory pk1) = _create(TARGET_PRICE, expiry);
        (, address vault2, PoolKey memory pk2) = _create(TARGET_PRICE, expiry + 1 days);

        // Settle pk1 only via callback
        vm.prank(CALLBACK_ADDR);
        hook.settle(pk1, true, 6_000e8);

        // pk1 settled, vault1 settled
        assertEq(uint256(hook.getMarketState(pk1).phase), uint256(OracleSettleHook.Phase.RESOLVED));
        assertTrue(CollateralVault(vault1).settled());

        // pk2 still trading, vault2 not settled
        assertEq(uint256(hook.getMarketState(pk2).phase), uint256(OracleSettleHook.Phase.TRADING));
        assertFalse(CollateralVault(vault2).settled());
    }

    // ==================== create(): authorization ====================

    function test_create_factoryNotAuthorizedOnHook_reverts() public {
        // Deploy a second hook WITHOUT calling setFactory on it
        uint160 flags     = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);
        address hookAddr2 = address(uint160(flags) | (1 << 20));
        deployCodeTo(
            "OracleSettleHook.sol:OracleSettleHook",
            abi.encode(manager, address(this)),
            hookAddr2
        );
        OracleSettleHook hook2 = OracleSettleHook(hookAddr2);
        hook2.setCallbackContract(CALLBACK_ADDR);
        // Deliberately skip: hook2.setFactory(factory2)

        QuestionFactory factory2 = new QuestionFactory(address(manager), address(usdc), hookAddr2);

        vm.expectRevert(OracleSettleHook.OnlyOwner.selector);
        factory2.create(TARGET_PRICE, expiry);
    }

    // ==================== Fuzz ====================

    function testFuzz_create_anyTargetPrice(int256 price) public {
        (,, PoolKey memory pk) = _create(price, expiry);
        assertEq(hook.getMarketState(pk).targetPrice, price);
    }

    function testFuzz_create_anyFutureExpiry(uint256 daysAhead) public {
        uint256 exp = block.timestamp + bound(daysAhead, 1, 365 days);
        (,, PoolKey memory pk) = _create(TARGET_PRICE, exp);
        assertEq(hook.getMarketState(pk).expiryTimestamp, exp);
    }

    function testFuzz_create_vaultAlwaysHasCorrectWiring(int256 price, uint256 daysAhead) public {
        uint256 exp = block.timestamp + bound(daysAhead, 1, 365 days);
        (, address vault, PoolKey memory pk) = _create(price, exp);

        (, address qYes, address qNo,) = factory.questions(factory.questionCount() - 1);
        assertEq(OutcomeToken(qYes).vault(), vault);
        assertEq(OutcomeToken(qNo).vault(),  vault);
        assertEq(hook.getMarketState(pk).vault, vault);
    }
}
