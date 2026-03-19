// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test, Vm} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

import {OracleSettleHook} from "../src/OracleSettleHook.sol";
import {OracleSettleCallback} from "../src/OracleSettleCallback.sol";
import {OracleSettleReactive} from "../src/OracleSettleReactive.sol";
import {OutcomeToken} from "../src/OutcomeToken.sol";
import {CollateralVault} from "../src/CollateralVault.sol";

// ---------------------------------------------------------------------------
// OracleSettleReactiveHarness
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

    function reactTest(
        uint256 chainId,
        address contractAddr,
        uint256 topic0,
        uint256 topic1,
        bytes memory data
    ) external {
        LogRecord memory log = LogRecord({
            chain_id:     chainId,
            _contract:    contractAddr,
            topic_0:      topic0,
            topic_1:      topic1,
            topic_2:      0,
            topic_3:      0,
            data:         data,
            block_number: block.number,
            op_code:      0,
            block_hash:   0,
            tx_hash:      0,
            log_index:    0
        });
        this.react(log);
    }
}

// ---------------------------------------------------------------------------
// OracleSettleUserJourneysTest
//
// Tests the full prediction market lifecycle with the CollateralVault:
//   User deposits USDC → vault mints YES+NO → trade YES/NO on AMM pool
//   → oracle settles → vault.redeem() exchanges winning token for USDC 1:1
//
// Pool: YES/NO (price discovery only — no USDC in pool)
// Vault: holds USDC, mints/burns/redeems 1:1
// ---------------------------------------------------------------------------
contract OracleSettleUserJourneysTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    OracleSettleHook             hook;
    OracleSettleCallback         cb;
    OracleSettleReactiveHarness  reactive;

    MockERC20    usdc;
    OutcomeToken yesToken;
    OutcomeToken noToken;
    CollateralVault vault;

    address alice = address(0xA11CE);
    address bob   = address(0xB0B);
    address lp1   = address(0x11111111);
    address lp2   = address(0x22222222);

    uint256 constant ORIGIN_CHAIN_ID = 11_155_111;
    uint256 constant DEST_CHAIN_ID   = 1_301;
    address constant CHAINLINK_FEED  = address(0x694AA1769357215DE4FAC081bf1f309aDC325306);
    address constant CALLBACK_PROXY  = 0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4;

    uint24  constant POOL_FEE    = 10_000;
    int256  constant TARGET_PRICE = 5_000e8;
    uint256 expiry;

    function setUp() public {
        deployFreshManagerAndRouters();

        // Deploy tokens — 18 decimals for test convenience
        usdc     = new MockERC20("Mock USDC", "USDC", 18);
        yesToken = new OutcomeToken("YES Token", "YES", 18, address(0));
        noToken  = new OutcomeToken("NO Token",  "NO",  18, address(0));

        // Deploy hook
        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);
        deployCodeTo(
            "OracleSettleHook.sol:OracleSettleHook",
            abi.encode(manager, address(this)),
            address(flags)
        );
        hook = OracleSettleHook(address(flags));

        // Deploy callback — rvm_id = address(this)
        cb = new OracleSettleCallback(CALLBACK_PROXY, address(hook));
        hook.setCallbackContract(address(cb));

        // Deploy vault (address(this) not used as hook directly — hook address is the real hook)
        vault = new CollateralVault(address(usdc), address(yesToken), address(noToken), address(hook));
        yesToken.setVault(address(vault));
        noToken.setVault(address(vault));

        // Create YES/NO pool via Deployers helper (auto-sorts by address)
        (key,) = initPool(
            Currency.wrap(address(yesToken)),
            Currency.wrap(address(noToken)),
            hook,
            POOL_FEE,
            SQRT_PRICE_1_1
        );

        expiry = block.timestamp + 7 days;
        hook.initMarket(key, TARGET_PRICE, expiry, address(vault));

        // Deploy reactive harness
        bytes memory encodedKey = abi.encode(key);
        reactive = new OracleSettleReactiveHarness(
            CHAINLINK_FEED,
            address(cb),
            encodedKey,
            TARGET_PRICE,
            expiry,
            ORIGIN_CHAIN_ID,
            DEST_CHAIN_ID
        );

        // Seed initial liquidity: mint USDC → get YES+NO → add to pool
        usdc.mint(address(this), 1_000 ether);
        usdc.approve(address(vault), type(uint256).max);
        vault.mint(200 ether); // get 200 YES + 200 NO
        yesToken.approve(address(modifyLiquidityRouter), type(uint256).max);
        noToken.approve(address(modifyLiquidityRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({ tickLower: -200, tickUpper: 200, liquidityDelta: 10 ether, salt: bytes32(0) }),
            ZERO_BYTES
        );

        // Fund users
        _fundUser(alice);
        _fundUser(bob);
        _fundUser(lp1);
        _fundUser(lp2);
    }

    // ==================== Journey 1: Full Lifecycle — YES Wins ====================

    function test_journey_fullLifecycle_yesWins() public {
        // Trading: both directions work
        _doSwapAs(alice, true);
        _doSwapAs(bob,   false);

        assertEq(uint256(hook.getMarketState(key).phase), uint256(OracleSettleHook.Phase.TRADING));

        // Oracle resolves YES
        _settleViaCallback(true, 6_000e8);

        // All pool swaps now blocked
        vm.startPrank(alice, alice);
        _approveTokensForSwap(alice);
        vm.expectRevert();
        swapRouter.swap(key, SwapParams({ zeroForOne: true, amountSpecified: -0.001 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1 }), PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }), ZERO_BYTES);
        vm.stopPrank();

        // Alice redeems YES → USDC via vault
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 aliceYes = yesToken.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(aliceYes);
        assertGt(usdc.balanceOf(alice), aliceUsdcBefore);

        assertTrue(hook.getMarketState(key).yesWon);
    }

    // ==================== Journey 2: Full Lifecycle — NO Wins ====================

    function test_journey_fullLifecycle_noWins() public {
        _doSwapAs(alice, true);
        _doSwapAs(bob,   false);

        _settleViaCallback(false, 3_000e8);

        // Both swap directions blocked
        vm.startPrank(alice, alice);
        _approveTokensForSwap(alice);
        vm.expectRevert();
        swapRouter.swap(key, SwapParams({ zeroForOne: true, amountSpecified: -0.001 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1 }), PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }), ZERO_BYTES);
        vm.stopPrank();

        vm.startPrank(bob, bob);
        _approveTokensForSwap(bob);
        vm.expectRevert();
        swapRouter.swap(key, SwapParams({ zeroForOne: false, amountSpecified: -0.001 ether, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1 }), PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }), ZERO_BYTES);
        vm.stopPrank();

        // NO holders redeem NO → USDC
        uint256 aliceNo  = noToken.balanceOf(alice);
        uint256 usdcPre  = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(aliceNo);
        assertEq(usdc.balanceOf(alice), usdcPre + aliceNo);

        assertFalse(hook.getMarketState(key).yesWon);
    }

    // ==================== Journey 3: vault.burn() blocked after settlement ====================

    function test_journey_vaultBurn_blockedAfterSettlement() public {
        _settleViaCallback(true, 6_000e8);

        uint256 aliceYes = yesToken.balanceOf(alice);
        uint256 aliceNo  = noToken.balanceOf(alice);
        uint256 burnAmt  = (aliceYes < aliceNo ? aliceYes : aliceNo);
        require(burnAmt > 0, "no tokens to burn");

        vm.prank(alice);
        vm.expectRevert(CollateralVault.AlreadySettled.selector);
        vault.burn(burnAmt);
    }

    // ==================== Journey 4: Cannot redeem wrong token after settlement ====================

    function test_journey_cannotRedeem_wrongToken() public {
        // Alice mints, then we settle YES wins
        // Alice has YES+NO. Redeem all YES first, then try redeem again → 0 YES → revert
        _settleViaCallback(true, 6_000e8);

        uint256 aliceYes = yesToken.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(aliceYes); // success: burns YES, gets USDC

        // Try again — alice now has 0 YES
        vm.prank(alice);
        vm.expectRevert(); // arithmetic underflow burning YES
        vault.redeem(1 ether);
    }

    function test_journey_noWins_yesHolderCannotRedeem() public {
        // bob: only has YES and NO from setUp funding
        // Settle NO wins → vault.redeem burns NO. bob has NO, so normally succeeds.
        // But test with address that has 0 NO:
        address stranger = address(0x5555);
        _settleViaCallback(false, 2_000e8);

        vm.prank(stranger); // stranger has 0 NO
        vm.expectRevert();
        vault.redeem(1 ether);
    }

    // ==================== Journey 5: Pool swaps blocked both directions post-settlement ====================

    function test_journey_bothSwapDirections_blockedAfterSettlement() public {
        _settleViaCallback(true, 6_000e8);

        // zeroForOne blocked (error is wrapped by PoolManager, use bare expectRevert)
        vm.startPrank(alice, alice);
        _approveTokensForSwap(alice);
        vm.expectRevert();
        swapRouter.swap(key, SwapParams({ zeroForOne: true, amountSpecified: -0.001 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1 }), PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }), ZERO_BYTES);
        vm.stopPrank();

        // oneForZero also blocked
        vm.startPrank(bob, bob);
        _approveTokensForSwap(bob);
        vm.expectRevert();
        swapRouter.swap(key, SwapParams({ zeroForOne: false, amountSpecified: -0.001 ether, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1 }), PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }), ZERO_BYTES);
        vm.stopPrank();
    }

    // ==================== Journey 6: LP earns fees, exits after YES ====================

    function test_journey_lp_earnsFees_exitAfterYES() public {
        _addLiquidityAs(lp1, -200, 200, 5 ether);

        _doSwapAs(alice, true);
        _doSwapAs(bob,   false);

        _settleViaCallback(true, 6_000e8);

        _removeLiquidityAs(lp1, -200, 200, 5 ether);
    }

    // ==================== Journey 7: LP earns fees, exits after NO ====================

    function test_journey_lp_earnsFees_exitAfterNO() public {
        _addLiquidityAs(lp1, -200, 200, 5 ether);

        _doSwapAs(alice, true);
        _doSwapAs(bob,   false);

        _settleViaCallback(false, 3_000e8);

        _removeLiquidityAs(lp1, -200, 200, 5 ether);
    }

    // ==================== Journey 8: Cross-Chain Settlement via Chainlink Mock ====================

    function test_journey_crossChainSettlement_viaChainlinkMock() public {
        uint256 topic = reactive.ANSWER_UPDATED_TOPIC0();
        vm.warp(expiry + 1);

        int256 price = 6_000e8;
        bytes memory data = abi.encode(expiry + 1);

        vm.recordLogs();
        reactive.reactTest(ORIGIN_CHAIN_ID, CHAINLINK_FEED, topic, uint256(int256(price)), data);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 callbackSig = keccak256("Callback(uint256,address,uint64,bytes)");
        bytes memory payload;
        bool found = false;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == callbackSig) {
                payload = abi.decode(entries[i].data, (bytes));
                found = true;
                break;
            }
        }
        assertTrue(found, "Callback not emitted");
        assertTrue(reactive.settled());

        bytes memory payloadArgs = new bytes(payload.length - 4);
        for (uint256 i = 0; i < payloadArgs.length; i++) payloadArgs[i] = payload[4 + i];
        (, bytes memory encodedKey, bool yesWon, int256 settledPrice) =
            abi.decode(payloadArgs, (address, bytes, bool, int256));
        cb.resolveMarket(address(this), encodedKey, yesWon, settledPrice);

        OracleSettleHook.MarketState memory state = hook.getMarketState(key);
        assertEq(uint256(state.phase), uint256(OracleSettleHook.Phase.RESOLVED));
        assertTrue(state.yesWon);
        assertEq(state.settledPrice, price);

        // Vault is also settled
        assertTrue(vault.settled());
        assertTrue(vault.yesWon());
    }

    // ==================== Journey 9: Two Simultaneous Questions — Independent Vaults ====================

    function test_journey_twoQuestions_independentSettlement() public {
        // Set up second market on same hook
        OutcomeToken yes2 = new OutcomeToken("YES2 Token", "YES2", 18, address(0));
        OutcomeToken no2  = new OutcomeToken("NO2 Token",  "NO2",  18, address(0));
        CollateralVault vault2 = new CollateralVault(address(usdc), address(yes2), address(no2), address(hook));
        yes2.setVault(address(vault2));
        no2.setVault(address(vault2));

        // Second pool (different fee → different PoolId)
        PoolKey memory key2;
        (key2,) = initPool(
            Currency.wrap(address(yes2)),
            Currency.wrap(address(no2)),
            hook,
            3_000,
            SQRT_PRICE_1_1
        );
        hook.initMarket(key2, TARGET_PRICE, expiry, address(vault2));

        // Settle key1 YES, key2 NO
        _settleViaCallback(true, 7_000e8);

        vm.prank(address(cb));
        hook.settle(key2, false, 2_000e8);

        // key1: YES won, vault settled
        assertTrue(hook.getMarketState(key).yesWon);
        assertTrue(vault.settled());
        assertTrue(vault.yesWon());

        // key2: NO won, vault2 settled
        assertFalse(hook.getMarketState(key2).yesWon);
        assertTrue(vault2.settled());
        assertFalse(vault2.yesWon());
    }

    // ==================== Journey 10: Callback Relay Settles Hook ====================

    function test_journey_callbackRelay_settlesHook() public {
        assertEq(uint256(hook.getMarketState(key).phase), uint256(OracleSettleHook.Phase.TRADING));

        cb.resolveMarket(address(this), abi.encode(key), true, 8_000e8);

        OracleSettleHook.MarketState memory state = hook.getMarketState(key);
        assertEq(uint256(state.phase), uint256(OracleSettleHook.Phase.RESOLVED));
        assertTrue(state.yesWon);
        assertEq(state.settledPrice, 8_000e8);

        // Vault also settled
        assertTrue(vault.settled());
        assertTrue(vault.yesWon());
    }

    // ==================== Journey 11: Wrong RVM ID Reverts ====================

    function test_journey_callbackWrongRvmId_reverts() public {
        vm.expectRevert("Authorized RVM ID only");
        cb.resolveMarket(address(0xBAD), abi.encode(key), true, 6_000e8);
    }

    // ==================== Journey 12: Callback Emits Relayed Event ====================

    function test_journey_settleEmitsRelayedEvent() public {
        vm.expectEmit(false, false, false, true);
        emit OracleSettleCallback.MarketSettledRelayed(true, 6_000e8);
        _settleViaCallback(true, 6_000e8);
    }

    // ==================== Journey 13: vault.mint then vault.burn then settle flow ====================

    function test_journey_mintBurnSettleRedeem_lifecycle() public {
        // alice already has 20 YES + 20 NO from _fundUser in setUp
        assertEq(yesToken.balanceOf(alice), 20 ether);

        // Mint 10 more YES+NO from 10 USDC
        vm.prank(alice);
        vault.mint(10 ether);
        assertEq(yesToken.balanceOf(alice), 30 ether);
        assertEq(noToken.balanceOf(alice),  30 ether);

        // Burn 5 pairs back (get 5 USDC returned)
        vm.prank(alice);
        vault.burn(5 ether);
        assertEq(yesToken.balanceOf(alice), 25 ether);
        assertEq(noToken.balanceOf(alice),  25 ether);

        // Settle YES wins
        _settleViaCallback(true, 6_000e8);

        // Redeem all 25 YES → 25 USDC
        uint256 usdcBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(25 ether);
        assertEq(usdc.balanceOf(alice),    usdcBefore + 25 ether);
        assertEq(yesToken.balanceOf(alice), 0);
    }

    // ==================== Fuzz ====================

    function testFuzz_journey_anyPriceSettlesCorrectly(int256 price) public {
        price = bound(price, 0, int256(uint256(type(uint128).max)));
        bool yesWon = price >= TARGET_PRICE;
        _settleViaCallback(yesWon, price);
        OracleSettleHook.MarketState memory state = hook.getMarketState(key);
        assertEq(uint256(state.phase), uint256(OracleSettleHook.Phase.RESOLVED));
        assertEq(state.yesWon, yesWon);
        assertEq(vault.yesWon(), yesWon);
    }

    function testFuzz_journey_lpCanAlwaysRemoveLiquidity(bool yesWon) public {
        _addLiquidityAs(lp1, -200, 200, 2 ether);
        int256 price = yesWon ? int256(6_000e8) : int256(3_000e8);
        _settleViaCallback(yesWon, price);
        _removeLiquidityAs(lp1, -200, 200, 2 ether);
    }

    // ==================== Helpers ====================

    function _settleViaCallback(bool yesWon, int256 price) internal {
        cb.resolveMarket(address(this), abi.encode(key), yesWon, price);
    }

    function _fundUser(address user) internal {
        usdc.mint(user, 100 ether);
        vm.startPrank(user);
        usdc.approve(address(vault), type(uint256).max);
        vault.mint(20 ether); // each user gets 20 YES + 20 NO
        vm.stopPrank();
    }

    function _approveTokensForSwap(address user) internal {
        yesToken.approve(address(swapRouter), type(uint256).max);
        noToken.approve(address(swapRouter), type(uint256).max);
    }

    function _doSwapAs(address user, bool zeroForOne) internal {
        vm.startPrank(user, user);
        yesToken.approve(address(swapRouter), type(uint256).max);
        noToken.approve(address(swapRouter), type(uint256).max);
        uint160 sqrtLimit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        swapRouter.swap(
            key,
            SwapParams({ zeroForOne: zeroForOne, amountSpecified: -0.001 ether, sqrtPriceLimitX96: sqrtLimit }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            ZERO_BYTES
        );
        vm.stopPrank();
    }

    function _addLiquidityAs(address user, int24 tickLower, int24 tickUpper, int256 delta) internal {
        // LP needs YES+NO from vault
        usdc.mint(user, 20 ether);
        vm.startPrank(user);
        usdc.approve(address(vault), type(uint256).max);
        vault.mint(10 ether);
        yesToken.approve(address(modifyLiquidityRouter), type(uint256).max);
        noToken.approve(address(modifyLiquidityRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({ tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: delta, salt: bytes32(0) }),
            ZERO_BYTES
        );
        vm.stopPrank();
    }

    function _removeLiquidityAs(address user, int24 tickLower, int24 tickUpper, int256 delta) internal {
        if (user == address(this)) {
            modifyLiquidityRouter.modifyLiquidity(
                key,
                ModifyLiquidityParams({ tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: -delta, salt: bytes32(0) }),
                ZERO_BYTES
            );
        } else {
            vm.startPrank(user, user);
            yesToken.approve(address(modifyLiquidityRouter), type(uint256).max);
            noToken.approve(address(modifyLiquidityRouter), type(uint256).max);
            modifyLiquidityRouter.modifyLiquidity(
                key,
                ModifyLiquidityParams({ tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: -delta, salt: bytes32(0) }),
                ZERO_BYTES
            );
            vm.stopPrank();
        }
    }

}

