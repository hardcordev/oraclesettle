// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {OracleSettleHook} from "../src/OracleSettleHook.sol";
import {QuestionFactory} from "../src/QuestionFactory.sol";
import {MockUSDC} from "../src/MockUSDC.sol";

/// @notice Deploys MockUSDC + new QuestionFactory, wires them to the existing hook, creates question #1.
/// Run with:
///   forge script script/RedeployWithMockUSDC.s.sol \
///     --rpc-url $UNICHAIN_SEPOLIA_RPC --broadcast \
///     --private-key $PRIVATE_KEY
contract RedeployWithMockUSDC is Script {
    address constant POOL_MANAGER = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;
    address constant HOOK         = 0x51C69Fcca69484F3598DFA0DA1A92c57104eE080;

    function run() external {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        vm.startBroadcast();

        // 1. Deploy MockUSDC (6 decimals, public mint)
        MockUSDC usdc = new MockUSDC();
        console.log("MockUSDC deployed at:", address(usdc));

        // 2. Mint 10,000 USDC to deployer for testing
        usdc.mint(deployer, 10_000e6);
        console.log("Minted 10,000 MockUSDC to deployer");

        // 3. Deploy new factory pointing to MockUSDC
        QuestionFactory factory = new QuestionFactory(POOL_MANAGER, address(usdc), HOOK);
        console.log("QuestionFactory deployed at:", address(factory));

        // 4. Wire factory into existing hook (setFactory is re-callable)
        OracleSettleHook(HOOK).setFactory(address(factory));
        console.log("hook.factory updated to new factory");

        // 5. Create question (target price passed via env, default $2280 = 228000000000)
        int256 targetPrice = int256(vm.envOr("TARGET_PRICE", uint256(228_000_000_000)));
        uint256 expiry     = vm.envOr("EXPIRY", uint256(1_773_953_220));

        (uint256 qId, address vault, bytes memory encodedKey) = factory.create(targetPrice, expiry);
        console.log("Question ID:", qId);
        console.log("Vault:", vault);
        console.log("EncodedKey (hex):");
        console.logBytes(encodedKey);

        vm.stopBroadcast();

        console.log("\n=== Update dashboard constants.ts with these values ===");
        console.log("MOCK_USDC=%s", address(usdc));
        console.log("FACTORY=%s", address(factory));
        console.log("VAULT=%s (question #%s)", vault, qId);
    }
}
