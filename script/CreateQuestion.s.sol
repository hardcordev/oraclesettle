// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {QuestionFactory} from "../src/QuestionFactory.sol";

/// @notice Creates a new prediction question via QuestionFactory.
///   Deploys YES token, NO token, and CollateralVault; initialises the YES/NO pool;
///   registers the market with OracleSettleHook.
///
/// Required env vars:
///   FACTORY_ADDRESS   — QuestionFactory deployed by DeployHook.s.sol
///   TARGET_PRICE      — int256 in Chainlink 8-decimal format (e.g. "500000000000" for $5,000)
///   EXPIRY_TIMESTAMP  — uint256 unix timestamp for oracle settlement window
///
/// Run with:
///   forge script script/CreateQuestion.s.sol --rpc-url $UNICHAIN_SEPOLIA_RPC --broadcast
///
/// After running, pass the printed ENCODED_KEY to DeployReactive.s.sol.
contract CreateQuestion is Script {
    function run() external {
        address factoryAddr  = vm.envAddress("FACTORY_ADDRESS");
        int256  targetPrice  = int256(vm.envUint("TARGET_PRICE"));
        uint256 expiry       = vm.envUint("EXPIRY_TIMESTAMP");

        vm.startBroadcast();

        QuestionFactory factory = QuestionFactory(factoryAddr);
        (uint256 questionId, address vault, bytes memory encodedKey) =
            factory.create(targetPrice, expiry);

        vm.stopBroadcast();

        (, address qYes, address qNo,) = factory.questions(questionId);

        console.log("=== Question Created ===");
        console.log("Question ID   :", questionId);
        console.log("Vault         :", vault);
        console.log("YES token     :", qYes);
        console.log("NO  token     :", qNo);
        console.log("Target price  :", uint256(targetPrice));
        console.log("Expiry        :", expiry);
        console.log("\nFor DeployReactive.s.sol, set:");
        console.log("CALLBACK_CONTRACT=<OracleSettleCallback address>");
        console.log("TARGET_PRICE=%d", uint256(targetPrice));
        console.log("EXPIRY_TIMESTAMP=%d", expiry);
        console.log("ENCODED_KEY=0x%s", _bytesToHex(encodedKey));
    }

    function _bytesToHex(bytes memory data) internal pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes memory str = new bytes(data.length * 2);
        for (uint256 i = 0; i < data.length; i++) {
            str[i * 2]     = alphabet[uint8(data[i] >> 4)];
            str[i * 2 + 1] = alphabet[uint8(data[i] & 0x0f)];
        }
        return string(str);
    }
}
