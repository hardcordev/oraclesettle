// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {OracleSettleReactive} from "../src/OracleSettleReactive.sol";

/// @notice Deploys OracleSettleReactive to Reactive Network (Lasna).
/// Required env vars:
///   CHAINLINK_FEED      — Chainlink ETH/USD feed on origin chain
///   CALLBACK_CONTRACT   — OracleSettleCallback address on Unichain
///   ENCODED_KEY         — hex-encoded ABI-encoded PoolKey bytes
///   TARGET_PRICE        — int256 target price in Chainlink 8-decimal format
///   EXPIRY_TIMESTAMP    — uint256 unix timestamp of market expiry
/// Run with:
///   forge script script/DeployReactive.s.sol --rpc-url $REACTIVE_LASNA_RPC --broadcast
contract DeployReactive is Script {
    // Ethereum Sepolia chain ID (use 1 for mainnet)
    uint256 constant ORIGIN_CHAIN_ID = 11_155_111;
    // Unichain Sepolia chain ID
    uint256 constant DEST_CHAIN_ID   = 1_301;

    // Chainlink ETH/USD Sepolia feed
    address constant ETH_USD_SEPOLIA = 0x694AA1769357215DE4FAC081bf1f309aDC325306;

    function run() external {
        address chainlinkFeed    = vm.envOr("CHAINLINK_FEED", ETH_USD_SEPOLIA);
        address callbackContract = vm.envAddress("CALLBACK_CONTRACT");
        bytes memory encodedKey  = vm.envBytes("ENCODED_KEY");
        int256 targetPrice       = int256(vm.envUint("TARGET_PRICE"));
        uint256 expiryTimestamp  = vm.envUint("EXPIRY_TIMESTAMP");

        vm.startBroadcast();

        OracleSettleReactive reactive = new OracleSettleReactive{value: 0.5 ether}(
            chainlinkFeed,
            callbackContract,
            encodedKey,
            targetPrice,
            expiryTimestamp,
            ORIGIN_CHAIN_ID,
            DEST_CHAIN_ID
        );

        console.log("OracleSettleReactive deployed at:", address(reactive));
        console.log("  chainlinkFeed:", chainlinkFeed);
        console.log("  callbackContract:", callbackContract);
        console.log("  targetPrice:", uint256(targetPrice));
        console.log("  expiryTimestamp:", expiryTimestamp);

        vm.stopBroadcast();
    }
}
