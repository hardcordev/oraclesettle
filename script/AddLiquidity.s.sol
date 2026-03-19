// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";

interface IPositionManager {
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
}

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @notice Adds initial liquidity to the YES/NO prediction pool on Unichain Sepolia.
/// Run with:
///   forge script script/AddLiquidity.s.sol \
///     --rpc-url $UNICHAIN_SEPOLIA_RPC --broadcast \
///     --private-key $PRIVATE_KEY
contract AddLiquidity is Script {
    address constant POOL_MANAGER  = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;
    address constant POSITION_MGR  = 0xf969Aee60879C54bAAed9F3eD26147Db216Fd664;
    address constant PERMIT2       = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant HOOK          = 0x51C69Fcca69484F3598DFA0DA1A92c57104eE080;

    // Q#0 in new factory
    address constant YES           = 0x022613f5e82C455499e281F76fB54A2100EA56B8;
    address constant NO            = 0x28Aa7915F18ab115e34DB372b7B5E2b73b42051C;

    uint24  constant FEE           = 10_000;
    int24   constant TICK_SPACING  = 200;

    // Wide range: covers prices from ~0.0003 to ~3500 (YES per NO)
    // Must be multiples of tickSpacing (200)
    int24   constant TICK_LOWER    = -20_000;
    int24   constant TICK_UPPER    =  20_000;

    function run() external {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        vm.startBroadcast();

        IERC20 yes = IERC20(YES);
        IERC20 no  = IERC20(NO);

        uint256 yesBal = yes.balanceOf(deployer);
        uint256 noBal  = no.balanceOf(deployer);
        require(yesBal > 0 && noBal > 0, "Need YES and NO tokens - mint first");

        // Use 90% of balance as liquidity, keep 10% for trading
        uint128 amt0 = uint128(yesBal * 9 / 10);
        uint128 amt1 = uint128(noBal  * 9 / 10);

        console.log("Adding liquidity: YES=%s NO=%s", amt0, amt1);

        // 1. Approve YES and NO to Permit2
        yes.approve(PERMIT2, type(uint256).max);
        no.approve(PERMIT2, type(uint256).max);

        // 2. Permit2: approve PositionManager to spend YES and NO
        uint160 maxAmt = type(uint160).max;
        uint48  exp    = type(uint48).max;
        IAllowanceTransfer(PERMIT2).approve(YES, POSITION_MGR, maxAmt, exp);
        IAllowanceTransfer(PERMIT2).approve(NO,  POSITION_MGR, maxAmt, exp);

        // 3. Build PoolKey (YES < NO numerically, so YES = currency0)
        PoolKey memory key = PoolKey({
            currency0:   Currency.wrap(YES),
            currency1:   Currency.wrap(NO),
            fee:         FEE,
            tickSpacing: TICK_SPACING,
            hooks:       IHooks(HOOK)
        });

        // 4. Add liquidity via helper to avoid stack-too-deep
        _addLiquidity(key, amt0, amt1, deployer);

        console.log("Liquidity added. Pool is ready for swaps.");
        vm.stopBroadcast();
    }

    function _addLiquidity(PoolKey memory key, uint128 amt0, uint128 amt1, address recipient) internal {
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION_FROM_DELTAS),
            uint8(Actions.SETTLE_PAIR)
        );
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(key, TICK_LOWER, TICK_UPPER, amt0, amt1, recipient, bytes(""));
        params[1] = abi.encode(Currency.wrap(YES), Currency.wrap(NO));
        IPositionManager(POSITION_MGR).modifyLiquidities(
            abi.encode(actions, params),
            block.timestamp + 300
        );
    }
}
