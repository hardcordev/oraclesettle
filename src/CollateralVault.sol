// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IERC20Minimal {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IOutcomeTokenMintable {
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
}

/// @title CollateralVault
/// @notice Holds USDC collateral backing YES+NO outcome token pairs.
///   - Before settlement: mint(amount) deposits USDC, mints equal YES+NO to caller.
///   - Before settlement: burn(amount) returns USDC by burning equal YES+NO from caller.
///   - After settlement:  redeem(amount) burns the winning token from caller, sends USDC.
/// @dev Only the hook may call settle(). All redemption post-settlement goes through this vault.
contract CollateralVault {
    IERC20Minimal  public immutable usdc;
    IOutcomeTokenMintable public immutable yesToken;
    IOutcomeTokenMintable public immutable noToken;
    address        public immutable hook;

    bool public settled;
    bool public yesWon;

    // --- Errors ---

    error AlreadySettled();
    error NotSettled();
    error OnlyHook();
    error ZeroAmount();

    // --- Events ---

    event TokensMinted(address indexed user, uint256 amount);
    event TokensBurned(address indexed user, uint256 amount);
    event MarketSettled(bool yesWon);
    event Redeemed(address indexed user, uint256 amount, bool redeemedYes);

    modifier onlyHook() {
        if (msg.sender != hook) revert OnlyHook();
        _;
    }

    constructor(address _usdc, address _yesToken, address _noToken, address _hook) {
        usdc     = IERC20Minimal(_usdc);
        yesToken = IOutcomeTokenMintable(_yesToken);
        noToken  = IOutcomeTokenMintable(_noToken);
        hook     = _hook;
    }

    /// @notice Deposit `amount` USDC; receive equal amounts of YES and NO tokens.
    function mint(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        usdc.transferFrom(msg.sender, address(this), amount);
        yesToken.mint(msg.sender, amount);
        noToken.mint(msg.sender, amount);
        emit TokensMinted(msg.sender, amount);
    }

    /// @notice Return `amount` each of YES and NO; receive `amount` USDC back. Pre-settlement only.
    function burn(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        if (settled) revert AlreadySettled();
        yesToken.burn(msg.sender, amount);
        noToken.burn(msg.sender, amount);
        usdc.transfer(msg.sender, amount);
        emit TokensBurned(msg.sender, amount);
    }

    /// @notice Called by hook to finalize the market outcome. Irreversible.
    function settle(bool _yesWon) external onlyHook {
        if (settled) revert AlreadySettled();
        settled = true;
        yesWon  = _yesWon;
        emit MarketSettled(_yesWon);
    }

    /// @notice Burn winning tokens to receive USDC 1:1. Post-settlement only.
    ///   YES won → burn YES from caller.
    ///   NO  won → burn NO  from caller.
    function redeem(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        if (!settled) revert NotSettled();
        bool isYes = yesWon;
        if (isYes) {
            yesToken.burn(msg.sender, amount);
        } else {
            noToken.burn(msg.sender, amount);
        }
        usdc.transfer(msg.sender, amount);
        emit Redeemed(msg.sender, amount, isYes);
    }
}
