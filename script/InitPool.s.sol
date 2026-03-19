// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {OracleSettleHook} from "../src/OracleSettleHook.sol";

/// @notice Initializes the prediction market pool on Unichain Sepolia.
/// Deploys mock YES and USDC tokens, creates the pool, and seeds initial liquidity.
/// Required env vars:
///   HOOK_ADDRESS — deployed OracleSettleHook address
/// Run with:
///   forge script script/InitPool.s.sol --rpc-url $UNICHAIN_SEPOLIA_RPC --broadcast
contract InitPool is Script {
    using PoolIdLibrary for PoolKey;

    address constant POOL_MANAGER    = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;

    // 1% fee, tickSpacing = fee/100*2 = 200
    uint24 constant POOL_FEE    = 10_000;
    int24  constant TICK_SPACING = 200;

    // $5,000 target price in Chainlink 8-decimal format
    int256 constant TARGET_PRICE = 5_000e8;

    // 7 days from deployment
    uint256 constant MARKET_DURATION = 7 days;

    // Starting price: 1:1 (probability = 0.5 for YES)
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    function run() external {
        address hookAddress = vm.envAddress("HOOK_ADDRESS");
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");

        vm.startBroadcast();

        // Deploy mock tokens
        MockERC20 usdc = new MockERC20("Mock USDC", "USDC", 6);
        MockERC20 yes  = new MockERC20("YES Token", "YES", 18);
        console.log("USDC deployed at:", address(usdc));
        console.log("YES deployed at:", address(yes));

        // Sort currencies (currency0 < currency1 by address)
        (Currency currency0, Currency currency1) = address(usdc) < address(yes)
            ? (Currency.wrap(address(usdc)), Currency.wrap(address(yes)))
            : (Currency.wrap(address(yes)), Currency.wrap(address(usdc)));

        // Build pool key
        PoolKey memory poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hookAddress)
        });

        // Initialize pool at 50/50 starting price
        IPoolManager(POOL_MANAGER).initialize(poolKey, SQRT_PRICE_1_1);
        console.log("Pool initialized. PoolId:");
        console.logBytes32(PoolId.unwrap(poolKey.toId()));

        // Configure the prediction market
        OracleSettleHook hook = OracleSettleHook(hookAddress);
        uint256 expiry = block.timestamp + MARKET_DURATION;
        hook.initMarket(poolKey, TARGET_PRICE, expiry, address(0));
        console.log("Market initialized. Target price:", uint256(TARGET_PRICE));
        console.log("Expiry timestamp:", expiry);

        // Print the ABI-encoded pool key (needed for DeployReactive.s.sol ENCODED_KEY)
        bytes memory encodedKey = abi.encode(poolKey);
        console.log("ENCODED_KEY (hex):");
        console.logBytes(encodedKey);

        vm.stopBroadcast();
    }
}
