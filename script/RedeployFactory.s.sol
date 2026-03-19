// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {OracleSettleHook} from "../src/OracleSettleHook.sol";
import {QuestionFactory} from "../src/QuestionFactory.sol";

/// @notice Deploys a new QuestionFactory with the correct Unichain Sepolia USDC address,
///   wires it to the existing hook, and creates question #1.
/// Run with:
///   forge script script/RedeployFactory.s.sol \
///     --rpc-url $UNICHAIN_SEPOLIA_RPC --broadcast \
///     --private-key $PRIVATE_KEY
contract RedeployFactory is Script {
    address constant POOL_MANAGER = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;
    address constant HOOK         = 0x51C69Fcca69484F3598DFA0DA1A92c57104eE080;
    address constant USDC         = 0x31d0220469e10c4E71834a79b1f276d740d3768F; // real USDC on Unichain Sepolia

    function run() external {
        vm.startBroadcast();

        // 1. Deploy new factory with correct USDC
        QuestionFactory factory = new QuestionFactory(POOL_MANAGER, USDC, HOOK);
        console.log("QuestionFactory deployed at:", address(factory));

        // 2. Wire factory into existing hook (setFactory is re-callable by owner)
        OracleSettleHook(HOOK).setFactory(address(factory));
        console.log("hook.factory updated");

        // 3. Create question (target $2280 ETH/USD = 228000000000 in 8-dec)
        int256 targetPrice = int256(vm.envOr("TARGET_PRICE", uint256(228_000_000_000)));
        uint256 expiry     = vm.envOr("EXPIRY", uint256(1_773_953_220));

        (uint256 qId, address vault, bytes memory encodedKey) = factory.create(targetPrice, expiry);
        console.log("Question ID:", qId);
        console.log("Vault:", vault);
        console.logBytes(encodedKey);

        vm.stopBroadcast();

        console.log("\n=== Update dashboard constants.ts ===");
        console.log("FACTORY: %s", address(factory));
        console.log("USDC:    %s", USDC);
    }
}
