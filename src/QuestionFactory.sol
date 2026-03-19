// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

import {OutcomeToken} from "./OutcomeToken.sol";
import {CollateralVault} from "./CollateralVault.sol";

interface IOracleSettleHookInit {
    function initMarket(PoolKey calldata key, int256 targetPrice, uint256 expiry, address vault) external;
}

/// @title QuestionFactory
/// @notice Deploys a fresh YES token, NO token, and CollateralVault per prediction question.
///   Initialises the YES/NO Uniswap v4 pool and registers the market with OracleSettleHook.
contract QuestionFactory {
    address public immutable poolManager;
    address public immutable usdc;
    address public immutable hook;

    uint24  public constant POOL_FEE       = 10_000;
    int24   public constant TICK_SPACING   = 200;
    uint160 public constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;

    struct Question {
        address vault;
        address yes;
        address no;
        bytes32 poolId;
    }

    mapping(uint256 => Question) public questions;
    uint256 public questionCount;

    event QuestionCreated(
        uint256 indexed questionId,
        address vault,
        address yes,
        address no,
        bytes32 poolId
    );

    constructor(address _poolManager, address _usdc, address _hook) {
        poolManager = _poolManager;
        usdc        = _usdc;
        hook        = _hook;
    }

    /// @notice Deploy a new prediction question.
    /// @param targetPrice  Chainlink 8-decimal target (e.g. 5000e8 for $5,000)
    /// @param expiry       Unix timestamp after which oracle settlement is valid
    /// @return questionId  Unique identifier for this question
    /// @return vault       Address of the deployed CollateralVault
    /// @return encodedKey  ABI-encoded PoolKey (pass to DeployReactive as ENCODED_KEY)
    function create(int256 targetPrice, uint256 expiry)
        external
        returns (uint256 questionId, address vault, bytes memory encodedKey)
    {
        // 1-2. Deploy outcome tokens with address(0) vault placeholder
        OutcomeToken yes = new OutcomeToken("YES Token", "YES", 6, address(0));
        OutcomeToken no  = new OutcomeToken("NO Token",  "NO",  6, address(0));

        // 3. Deploy collateral vault
        CollateralVault v = new CollateralVault(usdc, address(yes), address(no), hook);
        vault = address(v);

        // 4. Wire vault as the authorised minter on each token
        yes.setVault(vault);
        no.setVault(vault);

        // 5. Sort token addresses so currency0 < currency1
        (address t0, address t1) = address(yes) < address(no)
            ? (address(yes), address(no))
            : (address(no),  address(yes));

        // 6. Build PoolKey
        PoolKey memory poolKey = PoolKey({
            currency0:   Currency.wrap(t0),
            currency1:   Currency.wrap(t1),
            fee:         POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks:       IHooks(hook)
        });

        // 7. Initialise pool at 50/50 starting price
        IPoolManager(poolManager).initialize(poolKey, SQRT_PRICE_1_1);

        // 8. Register market with hook (hook must have set factory = address(this))
        IOracleSettleHookInit(hook).initMarket(poolKey, targetPrice, expiry, vault);

        // 9. Encode pool key for Reactive deployment
        encodedKey = abi.encode(poolKey);

        // 10. Store and emit
        questionId = questionCount++;
        bytes32 pid = keccak256(encodedKey);
        questions[questionId] = Question({vault: vault, yes: address(yes), no: address(no), poolId: pid});
        emit QuestionCreated(questionId, vault, address(yes), address(no), pid);
    }
}
