// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";

interface IOutcomeToken {
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
    function setVault(address _vault) external;
}

/// @title OutcomeToken
/// @notice Mintable/burnable ERC20 for YES and NO outcome tokens. Only the vault can mint/burn.
/// @dev decimals=6 matches USDC so 1 YES == 1 USDC in face value at settlement.
contract OutcomeToken is ERC20, IOutcomeToken {
    address public vault;

    error OnlyVault();
    error VaultAlreadySet();
    error ZeroAddress();

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    constructor(string memory name, string memory symbol, uint8 decimals_, address _vault)
        ERC20(name, symbol, decimals_)
    {
        vault = _vault;
    }

    /// @notice Set the vault. Can only be called once, when vault was address(0) at construction.
    function setVault(address _vault) external {
        if (vault != address(0)) revert VaultAlreadySet();
        if (_vault == address(0)) revert ZeroAddress();
        vault = _vault;
    }

    function mint(address to, uint256 amount) external onlyVault {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyVault {
        _burn(from, amount);
    }
}
