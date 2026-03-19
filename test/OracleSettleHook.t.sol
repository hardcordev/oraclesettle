// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {OracleSettleHook} from "../src/OracleSettleHook.sol";

/// @dev Minimal mock vault that records calls to settle()
contract MockVault {
    bool    public settleCalled;
    bool    public settledYesWon;
    uint256 public settleCallCount;

    function settle(bool _yesWon) external {
        settleCalled = true;
        settledYesWon = _yesWon;
        settleCallCount++;
    }
}

/// @dev Vault whose settle() always reverts — used to test hook's error propagation
contract RevertingVault {
    error VaultSettleReverted();
    function settle(bool) external pure {
        revert VaultSettleReverted();
    }
}

contract OracleSettleHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    OracleSettleHook hook;

    uint24  constant POOL_FEE     = 10_000;
    int256  constant TARGET_PRICE = 5_000e8;
    uint256 constant EXPIRY       = 2_000_000_000;

    address callbackAddr = address(0xCA11BAC4);
    address alice        = address(0xA1);

    // ==================== setUp ====================

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        hook = _deployFreshHook(0); // offset=0 → canonical test hook

        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency0)).approve(address(modifyLiquidityRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(modifyLiquidityRouter), type(uint256).max);

        (key,) = initPool(currency0, currency1, hook, POOL_FEE, SQRT_PRICE_1_1);
        hook.initMarket(key, TARGET_PRICE, EXPIRY, address(0));

        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({ tickLower: -200, tickUpper: 200, liquidityDelta: 10 ether, salt: bytes32(0) }),
            ZERO_BYTES
        );
    }

    // ==================== Helpers ====================

    /// Deploy a hook with callback already set at a unique address (offset must be unique per test).
    function _deployFreshHook(uint256 offset) internal returns (OracleSettleHook h) {
        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);
        address addr  = address(uint160(uint256(flags) | (offset << 20)));
        deployCodeTo("OracleSettleHook.sol:OracleSettleHook", abi.encode(manager, address(this)), addr);
        h = OracleSettleHook(addr);
        h.setCallbackContract(callbackAddr);
    }

    /// Deploy a hook WITHOUT wiring the callback (for testing setCallbackContract flows).
    function _deployBareHook(uint256 offset) internal returns (OracleSettleHook h) {
        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);
        address addr  = address(uint160(uint256(flags) | (offset << 20)));
        deployCodeTo("OracleSettleHook.sol:OracleSettleHook", abi.encode(manager, address(this)), addr);
        h = OracleSettleHook(addr);
    }

    function _settle(bool yesWon, int256 price) internal {
        vm.prank(callbackAddr);
        hook.settle(key, yesWon, price);
    }

    function _doSwap(bool zeroForOne) internal {
        uint160 sqrtLimit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        swapRouter.swap(
            key,
            SwapParams({ zeroForOne: zeroForOne, amountSpecified: -0.001 ether, sqrtPriceLimitX96: sqrtLimit }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            ZERO_BYTES
        );
    }

    function _addLiquidity(int24 tickLower, int24 tickUpper, int256 delta) internal {
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({ tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: delta, salt: bytes32(0) }),
            ZERO_BYTES
        );
    }

    function _removeLiquidity(int24 tickLower, int24 tickUpper, int256 delta) internal {
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({ tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: -delta, salt: bytes32(0) }),
            ZERO_BYTES
        );
    }

    // ==================== Setup & Initialization ====================

    function test_setup_marketInitialized() public view {
        OracleSettleHook.MarketState memory state = hook.getMarketState(key);
        assertTrue(state.initialized);
        assertEq(uint256(state.phase), uint256(OracleSettleHook.Phase.TRADING));
    }

    function test_initMarket_setsParams() public view {
        OracleSettleHook.MarketState memory state = hook.getMarketState(key);
        assertEq(state.targetPrice,     TARGET_PRICE);
        assertEq(state.expiryTimestamp, EXPIRY);
        assertFalse(state.yesWon);
        assertEq(state.settledPrice, 0);
        assertEq(state.vault,        address(0));
    }

    function test_initMarket_withVault_storesVault() public {
        MockVault mv = new MockVault();
        hook.initMarket(key, TARGET_PRICE, EXPIRY, address(mv));
        assertEq(hook.getMarketState(key).vault, address(mv));
    }

    function test_initMarket_onlyOwner_reverts() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(OracleSettleHook.OnlyOwner.selector);
        hook.initMarket(key, TARGET_PRICE, EXPIRY, address(0));
    }

    function test_initMarket_factoryCanCall() public {
        address factoryAddr = address(0xFACE);
        hook.setFactory(factoryAddr);
        vm.prank(factoryAddr);
        hook.initMarket(key, TARGET_PRICE, EXPIRY, address(0));
        assertTrue(hook.getMarketState(key).initialized);
    }

    function test_initMarket_nonOwnerNonFactory_reverts() public {
        hook.setFactory(address(0xFACE));
        vm.prank(address(0xDEAD));
        vm.expectRevert(OracleSettleHook.OnlyOwner.selector);
        hook.initMarket(key, TARGET_PRICE, EXPIRY, address(0));
    }

    function test_initMarket_emitsEvent() public {
        OracleSettleHook hook2 = _deployFreshHook(1);
        (PoolKey memory key2,) = initPool(currency0, currency1, hook2, 3_000, SQRT_PRICE_1_1);
        PoolId id2 = key2.toId();

        vm.expectEmit(true, false, false, true);
        emit OracleSettleHook.MarketInitialized(id2, TARGET_PRICE, EXPIRY);
        hook2.initMarket(key2, TARGET_PRICE, EXPIRY, address(0));
    }

    function test_initMarket_reinitialize_updatesParams() public {
        int256  newTarget = 10_000e8;
        uint256 newExpiry = EXPIRY + 1_000;
        hook.initMarket(key, newTarget, newExpiry, address(0));
        OracleSettleHook.MarketState memory state = hook.getMarketState(key);
        assertEq(state.targetPrice,     newTarget);
        assertEq(state.expiryTimestamp, newExpiry);
        assertTrue(state.initialized);
    }

    // ==================== setFactory ====================

    function test_setFactory_setsFactory() public {
        address f = address(0xFACE);
        hook.setFactory(f);
        assertEq(hook.factory(), f);
    }

    function test_setFactory_onlyOwner_reverts() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(OracleSettleHook.OnlyOwner.selector);
        hook.setFactory(address(0xFACE));
    }

    function test_setFactory_emitsFactorySet() public {
        address f = address(0xFACE);
        vm.expectEmit(true, false, false, false);
        emit OracleSettleHook.FactorySet(f);
        hook.setFactory(f);
    }

    function test_setFactory_canBeUpdated() public {
        hook.setFactory(address(0xFACE));
        hook.setFactory(address(0xBEEF)); // update is allowed
        assertEq(hook.factory(), address(0xBEEF));
    }

    // ==================== Hook Callbacks ====================

    function test_beforeInitialize_noopReturnsSelector() public {
        // beforeInitialize is exercised implicitly when pools are initialised;
        // verify permissions include the flag and that initialization succeeds
        OracleSettleHook hook2 = _deployFreshHook(2);
        (PoolKey memory key2,) = initPool(currency0, currency1, hook2, 3_000, SQRT_PRICE_1_1);
        // pool was created → beforeInitialize returned the correct selector
        OracleSettleHook.MarketState memory state = hook2.getMarketState(key2);
        assertEq(uint256(state.phase), uint256(OracleSettleHook.Phase.TRADING));
    }

    // ==================== beforeSwap: TRADING Phase ====================

    function test_beforeSwap_trading_allowsAllDirections() public {
        _doSwap(true);
        _doSwap(false);
    }

    // ==================== beforeSwap: RESOLVED Phase ====================

    function test_beforeSwap_resolved_blocksZeroForOne() public {
        _settle(true, 6_000e8);
        vm.expectRevert();
        _doSwap(true);
    }

    function test_beforeSwap_resolved_blocksOneForZero() public {
        _settle(true, 6_000e8);
        vm.expectRevert();
        _doSwap(false);
    }

    function test_beforeSwap_resolvedNO_blocksAllSwaps() public {
        _settle(false, 3_000e8);
        vm.expectRevert();
        _doSwap(true);
        vm.expectRevert();
        _doSwap(false);
    }

    function test_beforeSwap_resolvedYES_blocksBothDirections() public {
        _settle(true, 8_000e8);
        // zeroForOne blocked
        vm.expectRevert();
        _doSwap(true);
        // oneForZero also blocked (redemption goes through vault, not pool)
        vm.expectRevert();
        _doSwap(false);
    }

    // ==================== settle() ====================

    function test_settle_setsResolvedPhase() public {
        _settle(true, 6_000e8);
        assertEq(uint256(hook.getMarketState(key).phase), uint256(OracleSettleHook.Phase.RESOLVED));
    }

    function test_settle_onlyCallback_reverts() public {
        vm.expectRevert(OracleSettleHook.OnlyCallback.selector);
        hook.settle(key, true, 6_000e8);
    }

    function test_settle_alreadySettled_reverts() public {
        _settle(true, 6_000e8);
        vm.prank(callbackAddr);
        vm.expectRevert(OracleSettleHook.MarketAlreadySettled.selector);
        hook.settle(key, false, 4_000e8);
    }

    function test_settle_emitsMarketSettledEvent() public {
        PoolId id = key.toId();
        vm.expectEmit(true, false, false, true);
        emit OracleSettleHook.MarketSettled(id, true, 6_000e8);
        _settle(true, 6_000e8);
    }

    function test_settle_yesWon_true_setsCorrectly() public {
        _settle(true, 6_000e8);
        assertTrue(hook.getMarketState(key).yesWon);
    }

    function test_settle_yesWon_false_setsCorrectly() public {
        _settle(false, 3_000e8);
        assertFalse(hook.getMarketState(key).yesWon);
    }

    function test_settle_storesSettledPrice() public {
        int256 price = 7_777e8;
        _settle(true, price);
        assertEq(hook.getMarketState(key).settledPrice, price);
    }

    function test_settle_callsVaultSettle_yesWon() public {
        MockVault mv = new MockVault();
        hook.initMarket(key, TARGET_PRICE, EXPIRY, address(mv));
        _settle(true, 6_000e8);
        assertTrue(mv.settleCalled());
        assertTrue(mv.settledYesWon());
        assertEq(mv.settleCallCount(), 1);
    }

    function test_settle_callsVaultSettle_noWon() public {
        MockVault mv = new MockVault();
        hook.initMarket(key, TARGET_PRICE, EXPIRY, address(mv));
        _settle(false, 3_000e8);
        assertTrue(mv.settleCalled());
        assertFalse(mv.settledYesWon());
    }

    function test_settle_noVault_doesNotRevert() public {
        // address(0) vault: settle must complete without touching vault
        _settle(true, 6_000e8);
        assertEq(uint256(hook.getMarketState(key).phase), uint256(OracleSettleHook.Phase.RESOLVED));
    }

    function test_settle_revertingVault_propagatesRevert() public {
        RevertingVault rv = new RevertingVault();
        hook.initMarket(key, TARGET_PRICE, EXPIRY, address(rv));
        vm.prank(callbackAddr);
        vm.expectRevert(RevertingVault.VaultSettleReverted.selector);
        hook.settle(key, true, 6_000e8);
    }

    function test_settle_negativePrice_storedCorrectly() public {
        int256 negPrice = -1_000e8;
        _settle(false, negPrice);
        OracleSettleHook.MarketState memory state = hook.getMarketState(key);
        assertEq(state.settledPrice, negPrice);
        assertFalse(state.yesWon);
    }

    function test_settle_priceBoundary_equalsTarget_yesWins() public {
        // Reactive determines yesWon = (price >= targetPrice); hook stores what it's told
        _settle(true, TARGET_PRICE);
        assertTrue(hook.getMarketState(key).yesWon);
        assertEq(hook.getMarketState(key).settledPrice, TARGET_PRICE);
    }

    // ==================== getMarketState ====================

    function test_getMarketState_tradingPhase() public view {
        OracleSettleHook.MarketState memory state = hook.getMarketState(key);
        assertEq(uint256(state.phase), uint256(OracleSettleHook.Phase.TRADING));
        assertTrue(state.initialized);
    }

    function test_getMarketState_resolvedPhase() public {
        _settle(true, 6_000e8);
        OracleSettleHook.MarketState memory state = hook.getMarketState(key);
        assertEq(uint256(state.phase), uint256(OracleSettleHook.Phase.RESOLVED));
        assertTrue(state.yesWon);
        assertEq(state.settledPrice, 6_000e8);
    }

    // ==================== Liquidity Management ====================

    function test_lp_canAddLiquidity_beforeSettle() public {
        _addLiquidity(-200, 200, 1 ether);
    }

    function test_lp_canRemoveLiquidity_beforeSettle() public {
        _addLiquidity(-200, 200, 1 ether);
        _removeLiquidity(-200, 200, 1 ether);
    }

    function test_lp_canRemoveLiquidity_afterSettle() public {
        _addLiquidity(-200, 200, 1 ether);
        _settle(false, 3_000e8);
        _removeLiquidity(-200, 200, 1 ether); // liquidity ops never blocked
    }

    // ==================== Multiple Markets ====================

    function test_multipleMarkets_independentState() public {
        OracleSettleHook hook2 = _deployFreshHook(3);
        (PoolKey memory key2,) = initPool(currency0, currency1, hook2, 3_000, SQRT_PRICE_1_1);
        hook2.initMarket(key2, TARGET_PRICE, EXPIRY, address(0));

        vm.prank(callbackAddr);
        hook2.settle(key2, true, 6_000e8);

        assertEq(uint256(hook.getMarketState(key).phase),   uint256(OracleSettleHook.Phase.TRADING));
        assertEq(uint256(hook2.getMarketState(key2).phase), uint256(OracleSettleHook.Phase.RESOLVED));
    }

    function test_uninitializedMarket_defaultBehavior() public {
        OracleSettleHook hook3 = _deployFreshHook(4);
        (PoolKey memory key3,) = initPool(currency0, currency1, hook3, 3_000, SQRT_PRICE_1_1);

        OracleSettleHook.MarketState memory state = hook3.getMarketState(key3);
        assertEq(uint256(state.phase), uint256(OracleSettleHook.Phase.TRADING));
        assertFalse(state.initialized);

        // Uninitialized market is still in TRADING → swaps pass through
        MockERC20(Currency.unwrap(currency0)).approve(address(modifyLiquidityRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(modifyLiquidityRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity(
            key3,
            ModifyLiquidityParams({ tickLower: -60, tickUpper: 60, liquidityDelta: 10 ether, salt: bytes32(0) }),
            ZERO_BYTES
        );
        swapRouter.swap(
            key3,
            SwapParams({ zeroForOne: true, amountSpecified: -0.001 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1 }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            ZERO_BYTES
        );
    }

    // ==================== Edge Cases ====================

    function test_targetPrice_zero_worksCorrectly() public {
        OracleSettleHook hook4 = _deployFreshHook(5);
        (PoolKey memory key4,) = initPool(currency0, currency1, hook4, 3_000, SQRT_PRICE_1_1);
        hook4.initMarket(key4, 0, EXPIRY, address(0));
        vm.prank(callbackAddr);
        hook4.settle(key4, true, 1e8);
        assertTrue(hook4.getMarketState(key4).yesWon);
    }

    function test_marketPhase_cannotTransitionBackToTrading() public {
        _settle(true, 6_000e8);
        vm.prank(callbackAddr);
        vm.expectRevert(OracleSettleHook.MarketAlreadySettled.selector);
        hook.settle(key, false, 3_000e8);
        assertTrue(hook.getMarketState(key).yesWon); // still true
    }

    function test_hookPermissions_correct() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeInitialize);
        assertFalse(p.afterInitialize);
        assertFalse(p.beforeAddLiquidity);
        assertFalse(p.afterAddLiquidity);
        assertFalse(p.beforeRemoveLiquidity);
        assertFalse(p.afterRemoveLiquidity);
        assertTrue(p.beforeSwap);
        assertFalse(p.afterSwap);
        assertFalse(p.beforeDonate);
        assertFalse(p.afterDonate);
        assertFalse(p.beforeSwapReturnDelta);
        assertFalse(p.afterSwapReturnDelta);
        assertFalse(p.afterAddLiquidityReturnDelta);
        assertFalse(p.afterRemoveLiquidityReturnDelta);
    }

    // ==================== setCallbackContract ====================

    function test_setCallbackContract_onlyOwner() public view {
        assertEq(hook.callbackContract(), callbackAddr);
    }

    function test_setCallbackContract_zeroAddress_reverts() public {
        OracleSettleHook freshHook = _deployBareHook(6);
        vm.expectRevert(OracleSettleHook.ZeroAddress.selector);
        freshHook.setCallbackContract(address(0));
    }

    function test_setCallbackContract_alreadySet_reverts() public {
        OracleSettleHook freshHook = _deployBareHook(7);
        freshHook.setCallbackContract(callbackAddr);
        vm.expectRevert(OracleSettleHook.CallbackAlreadySet.selector);
        freshHook.setCallbackContract(address(0xBEEF));
    }

    function test_setCallbackContract_nonOwner_reverts() public {
        OracleSettleHook freshHook = _deployBareHook(8);
        vm.prank(address(0xDEAD));
        vm.expectRevert(OracleSettleHook.OnlyOwner.selector);
        freshHook.setCallbackContract(callbackAddr);
    }

    function test_setCallbackContract_emitsEvent() public {
        OracleSettleHook freshHook = _deployBareHook(9);
        vm.expectEmit(true, false, false, false);
        emit OracleSettleHook.CallbackContractSet(callbackAddr);
        freshHook.setCallbackContract(callbackAddr);
    }

    // ==================== Fuzz ====================

    function testFuzz_settle_anySettledPrice(int256 price) public {
        bool yesWon = (price >= TARGET_PRICE);
        _settle(yesWon, price);
        OracleSettleHook.MarketState memory state = hook.getMarketState(key);
        assertEq(uint256(state.phase), uint256(OracleSettleHook.Phase.RESOLVED));
        assertEq(state.settledPrice,   price);
        assertEq(state.yesWon,         yesWon);
    }

    function testFuzz_initMarket_anyTargetPrice(int256 targetPrice) public {
        hook.initMarket(key, targetPrice, EXPIRY, address(0));
        assertEq(hook.getMarketState(key).targetPrice, targetPrice);
        assertTrue(hook.getMarketState(key).initialized);
    }

    function testFuzz_swapAmount_tradingPhase(uint128 amount) public {
        uint256 bounded = bound(uint256(amount), 1, 0.1 ether);
        swapRouter.swap(
            key,
            SwapParams({ zeroForOne: true, amountSpecified: -int256(bounded), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1 }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            ZERO_BYTES
        );
    }

    function testFuzz_settle_vaultCalledWithCorrectOutcome(bool yesWon, int256 price) public {
        MockVault mv = new MockVault();
        hook.initMarket(key, TARGET_PRICE, EXPIRY, address(mv));
        _settle(yesWon, price);
        assertEq(mv.settledYesWon(), yesWon);
        assertEq(mv.settleCallCount(), 1);
    }

    function testFuzz_initMarket_anyExpiry(uint256 expiry) public {
        hook.initMarket(key, TARGET_PRICE, expiry, address(0));
        assertEq(hook.getMarketState(key).expiryTimestamp, expiry);
    }
}
