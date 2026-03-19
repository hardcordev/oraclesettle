// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {OutcomeToken} from "../src/OutcomeToken.sol";

contract OutcomeTokenTest is Test {
    OutcomeToken token;

    address vault   = address(0x1111);
    address alice   = address(0xA1);
    address bob     = address(0xB0B);
    address nonVault = address(0xDEAD);

    function setUp() public {
        // Deploy with address(0) vault placeholder, then wire it
        token = new OutcomeToken("YES Token", "YES", 18, address(0));
        token.setVault(vault);
    }

    // ==================== Constructor ====================

    function test_constructor_setsNameSymbolDecimals() public view {
        assertEq(token.name(),     "YES Token");
        assertEq(token.symbol(),   "YES");
        assertEq(token.decimals(), 18);
    }

    function test_constructor_withVault_vaultSetImmediately() public {
        OutcomeToken t = new OutcomeToken("NO Token", "NO", 6, vault);
        assertEq(t.vault(), vault);
    }

    function test_constructor_withZeroVault_vaultIsZero() public {
        OutcomeToken t = new OutcomeToken("NO Token", "NO", 6, address(0));
        assertEq(t.vault(), address(0));
    }

    function test_constructor_6decimals_storedCorrectly() public {
        OutcomeToken t = new OutcomeToken("NO Token", "NO", 6, address(0));
        assertEq(t.decimals(), 6);
    }

    // ==================== setVault ====================

    function test_setVault_setsVaultAddress() public view {
        assertEq(token.vault(), vault);
    }

    function test_setVault_canOnlyBeCalledOnce() public {
        // Try to set again — must revert
        vm.expectRevert(OutcomeToken.VaultAlreadySet.selector);
        token.setVault(address(0xBEEF));
    }

    function test_setVault_zeroAddress_reverts() public {
        OutcomeToken t = new OutcomeToken("NO Token", "NO", 18, address(0));
        vm.expectRevert(OutcomeToken.ZeroAddress.selector);
        t.setVault(address(0));
    }

    function test_setVault_whenAlreadySetInConstructor_reverts() public {
        OutcomeToken t = new OutcomeToken("YES Token", "YES", 18, vault);
        vm.expectRevert(OutcomeToken.VaultAlreadySet.selector);
        t.setVault(address(0xBEEF));
    }

    function test_setVault_calledByAnyone_succeeds() public {
        // setVault has no access control — any caller can set it once
        OutcomeToken t = new OutcomeToken("NO Token", "NO", 18, address(0));
        vm.prank(alice);
        t.setVault(vault);
        assertEq(t.vault(), vault);
    }

    // ==================== mint ====================

    function test_mint_byVault_mintsTokens() public {
        vm.prank(vault);
        token.mint(alice, 100 ether);
        assertEq(token.balanceOf(alice), 100 ether);
        assertEq(token.totalSupply(),    100 ether);
    }

    function test_mint_byNonVault_reverts() public {
        vm.prank(nonVault);
        vm.expectRevert(OutcomeToken.OnlyVault.selector);
        token.mint(alice, 100 ether);
    }

    function test_mint_byMsgSenderNotVault_reverts() public {
        // Even the token deployer can't mint without being the vault
        vm.expectRevert(OutcomeToken.OnlyVault.selector);
        token.mint(alice, 1 ether);
    }

    function test_mint_zeroAmount_succeeds() public {
        // ERC20 allows minting 0 — OutcomeToken does not guard against it
        vm.prank(vault);
        token.mint(alice, 0);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_mint_accumulatesBalance() public {
        vm.prank(vault);
        token.mint(alice, 50 ether);
        vm.prank(vault);
        token.mint(alice, 30 ether);
        assertEq(token.balanceOf(alice), 80 ether);
        assertEq(token.totalSupply(),    80 ether);
    }

    // ==================== burn ====================

    function test_burn_byVault_burnsTokens() public {
        vm.prank(vault);
        token.mint(alice, 100 ether);
        vm.prank(vault);
        token.burn(alice, 60 ether);
        assertEq(token.balanceOf(alice), 40 ether);
        assertEq(token.totalSupply(),    40 ether);
    }

    function test_burn_byNonVault_reverts() public {
        vm.prank(vault);
        token.mint(alice, 100 ether);
        vm.prank(nonVault);
        vm.expectRevert(OutcomeToken.OnlyVault.selector);
        token.burn(alice, 50 ether);
    }

    function test_burn_exceedsBalance_reverts() public {
        vm.prank(vault);
        token.mint(alice, 10 ether);
        vm.prank(vault);
        vm.expectRevert(); // arithmetic underflow
        token.burn(alice, 11 ether);
    }

    function test_burn_exactBalance_leavesZero() public {
        vm.prank(vault);
        token.mint(alice, 10 ether);
        vm.prank(vault);
        token.burn(alice, 10 ether);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(),    0);
    }

    // ==================== ERC20 standard flows ====================

    function test_erc20_transfer_movesTokens() public {
        vm.prank(vault);
        token.mint(alice, 100 ether);
        vm.prank(alice);
        token.transfer(bob, 30 ether);
        assertEq(token.balanceOf(alice), 70 ether);
        assertEq(token.balanceOf(bob),   30 ether);
    }

    function test_erc20_transferExceedsBalance_reverts() public {
        vm.prank(vault);
        token.mint(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert();
        token.transfer(bob, 11 ether);
    }

    function test_erc20_approve_and_transferFrom_works() public {
        vm.prank(vault);
        token.mint(alice, 100 ether);
        vm.prank(alice);
        token.approve(bob, 50 ether);
        assertEq(token.allowance(alice, bob), 50 ether);
        vm.prank(bob);
        token.transferFrom(alice, bob, 50 ether);
        assertEq(token.balanceOf(alice), 50 ether);
        assertEq(token.balanceOf(bob),   50 ether);
    }

    function test_erc20_transferFromExceedsAllowance_reverts() public {
        vm.prank(vault);
        token.mint(alice, 100 ether);
        vm.prank(alice);
        token.approve(bob, 10 ether);
        vm.prank(bob);
        vm.expectRevert();
        token.transferFrom(alice, bob, 11 ether);
    }

    function test_erc20_transferredTokens_stillBurnableByVault() public {
        vm.prank(vault);
        token.mint(alice, 100 ether);
        vm.prank(alice);
        token.transfer(bob, 40 ether);
        // Vault can burn from bob (vault.burn is normally called on msg.sender,
        // but the underlying _burn accepts any 'from' address)
        vm.prank(vault);
        token.burn(bob, 40 ether);
        assertEq(token.balanceOf(bob), 0);
    }

    // ==================== Fuzz ====================

    function testFuzz_mint_anyAmount(uint256 amount) public {
        amount = bound(amount, 0, type(uint128).max);
        vm.prank(vault);
        token.mint(alice, amount);
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.totalSupply(),    amount);
    }

    function testFuzz_mint_burn_roundtrip(uint256 amount) public {
        amount = bound(amount, 1, type(uint128).max);
        vm.prank(vault);
        token.mint(alice, amount);
        vm.prank(vault);
        token.burn(alice, amount);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(),    0);
    }

    function testFuzz_onlyVault_mintReverts(address caller) public {
        vm.assume(caller != vault);
        vm.prank(caller);
        vm.expectRevert(OutcomeToken.OnlyVault.selector);
        token.mint(alice, 1 ether);
    }

    function testFuzz_onlyVault_burnReverts(address caller) public {
        vm.assume(caller != vault);
        vm.prank(vault);
        token.mint(alice, 10 ether);
        vm.prank(caller);
        vm.expectRevert(OutcomeToken.OnlyVault.selector);
        token.burn(alice, 1 ether);
    }

    function testFuzz_transfer_preservesTotalSupply(uint128 mintAmt, uint128 transferAmt) public {
        vm.assume(transferAmt <= mintAmt);
        vm.prank(vault);
        token.mint(alice, mintAmt);
        vm.prank(alice);
        token.transfer(bob, transferAmt);
        assertEq(token.totalSupply(), mintAmt); // transfer doesn't change supply
        assertEq(token.balanceOf(alice) + token.balanceOf(bob), mintAmt);
    }
}
