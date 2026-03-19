// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

import {OracleSettleHook} from "../src/OracleSettleHook.sol";
import {OracleSettleCallback} from "../src/OracleSettleCallback.sol";
import {QuestionFactory} from "../src/QuestionFactory.sol";

/// @notice Deploys OracleSettleHook, OracleSettleCallback, and QuestionFactory to Unichain Sepolia.
/// Run with:
///   forge script script/DeployHook.s.sol --rpc-url $UNICHAIN_SEPOLIA_RPC --broadcast
contract DeployHook is Script {
    // Unichain Sepolia addresses
    address constant POOL_MANAGER   = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;
    address constant CALLBACK_PROXY = 0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4;

    // USDC on Unichain Sepolia (override via USDC_ADDRESS env var)
    address constant USDC_DEFAULT   = 0x31d0220469e10c4E71834a79b1f276d740d3768F; // USDC on Unichain Sepolia

    function run() external {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address usdc     = vm.envOr("USDC_ADDRESS", USDC_DEFAULT);
        vm.startBroadcast();

        // Compute required flag bits
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
        );

        // Mine CREATE2 salt so the hook address encodes the correct flag bits.
        // Must use CREATE2_FACTORY (forge-std constant = 0x4e59b44847b379578588920cA78FbF26c0B4956C)
        // because `new Hook{salt: s}()` in a broadcast script is always routed through that factory.
        bytes memory creationCode    = type(OracleSettleHook).creationCode;
        bytes memory constructorArgs = abi.encode(IPoolManager(POOL_MANAGER), deployer);

        (address hookAddress, bytes32 salt) = HookMiner.find(
            CREATE2_FACTORY,
            flags,
            creationCode,
            constructorArgs
        );

        // Deploy hook
        OracleSettleHook hook = new OracleSettleHook{salt: salt}(
            IPoolManager(POOL_MANAGER),
            deployer
        );
        require(address(hook) == hookAddress, "Hook address mismatch");
        console.log("OracleSettleHook deployed at:", address(hook));

        // Deploy callback
        OracleSettleCallback cb = new OracleSettleCallback(CALLBACK_PROXY, address(hook));
        console.log("OracleSettleCallback deployed at:", address(cb));

        // Wire callback -> hook
        hook.setCallbackContract(address(cb));
        console.log("Callback contract set on hook.");

        // Deploy factory
        QuestionFactory factory = new QuestionFactory(POOL_MANAGER, usdc, address(hook));
        console.log("QuestionFactory deployed at:", address(factory));

        // Authorise factory to call hook.initMarket()
        hook.setFactory(address(factory));
        console.log("Factory set on hook.");

        vm.stopBroadcast();

        console.log("\n=== Export these for subsequent scripts ===");
        console.log("HOOK_ADDRESS=%s", address(hook));
        console.log("CALLBACK_ADDRESS=%s", address(cb));
        console.log("FACTORY_ADDRESS=%s", address(factory));
    }
}
