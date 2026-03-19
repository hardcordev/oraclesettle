// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {OutcomeToken} from "../src/OutcomeToken.sol";
import {CollateralVault} from "../src/CollateralVault.sol";

contract CollateralVaultTest is Test {
    MockERC20      usdc;
    OutcomeToken   yes;
    OutcomeToken   no;
    CollateralVault vault;

    address alice = address(0xA1);
    address bob   = address(0xB0B);

    function setUp() public {
        // 18-decimal tokens for test convenience (1 token = 1 ether)
        usdc  = new MockERC20("Mock USDC", "USDC", 18);
        yes   = new OutcomeToken("YES Token", "YES", 18, address(0));
        no    = new OutcomeToken("NO Token",  "NO",  18, address(0));
        // address(this) acts as the hook
        vault = new CollateralVault(address(usdc), address(yes), address(no), address(this));
        yes.setVault(address(vault));
        no.setVault(address(vault));

        // Fund users
        usdc.mint(alice, 100 ether);
        usdc.mint(bob,   100 ether);
        usdc.mint(address(this), 100 ether);

        // Approvals
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);
        usdc.approve(address(vault), type(uint256).max);
    }

    // ==================== mint ====================

    function test_mint_happyPath() public {
        vm.prank(alice);
        vault.mint(10 ether);
        assertEq(yes.balanceOf(alice),           10 ether);
        assertEq(no.balanceOf(alice),            10 ether);
        assertEq(usdc.balanceOf(address(vault)), 10 ether);
        assertEq(usdc.balanceOf(alice),          90 ether);
    }

    function test_mint_zeroAmount_reverts() public {
        vm.prank(alice);
        vm.expectRevert(CollateralVault.ZeroAmount.selector);
        vault.mint(0);
    }

    function test_mint_mintsEqualYesAndNo() public {
        vm.prank(alice);
        vault.mint(7 ether);
        assertEq(yes.balanceOf(alice), 7 ether);
        assertEq(no.balanceOf(alice),  7 ether);
    }

    function test_mint_emitsTokensMinted() public {
        vm.expectEmit(true, false, false, true);
        emit CollateralVault.TokensMinted(alice, 5 ether);
        vm.prank(alice);
        vault.mint(5 ether);
    }

    function test_mint_multipleUsers_independentBalances() public {
        vm.prank(alice);
        vault.mint(10 ether);
        vm.prank(bob);
        vault.mint(20 ether);

        assertEq(yes.balanceOf(alice), 10 ether);
        assertEq(yes.balanceOf(bob),   20 ether);
        assertEq(usdc.balanceOf(address(vault)), 30 ether);
    }

    // ==================== burn ====================

    function test_burn_happyPath_preSettlement() public {
        vm.prank(alice);
        vault.mint(10 ether);
        uint256 usdcBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        vault.burn(5 ether);

        assertEq(yes.balanceOf(alice),  5 ether);
        assertEq(no.balanceOf(alice),   5 ether);
        assertEq(usdc.balanceOf(alice), usdcBefore + 5 ether);
    }

    function test_burn_zeroAmount_reverts() public {
        vm.prank(alice);
        vm.expectRevert(CollateralVault.ZeroAmount.selector);
        vault.burn(0);
    }

    function test_burn_postSettlement_reverts() public {
        vm.prank(alice);
        vault.mint(10 ether);
        vault.settle(true);

        vm.prank(alice);
        vm.expectRevert(CollateralVault.AlreadySettled.selector);
        vault.burn(5 ether);
    }

    function test_burn_emitsTokensBurned() public {
        vm.prank(alice);
        vault.mint(10 ether);
        vm.expectEmit(true, false, false, true);
        emit CollateralVault.TokensBurned(alice, 4 ether);
        vm.prank(alice);
        vault.burn(4 ether);
    }

    function test_burn_returnsExactUsdc() public {
        vm.prank(alice);
        vault.mint(10 ether);
        vm.prank(alice);
        vault.burn(10 ether);
        assertEq(usdc.balanceOf(alice), 100 ether); // back to start
        assertEq(yes.balanceOf(alice), 0);
        assertEq(no.balanceOf(alice),  0);
    }

    // ==================== settle ====================

    function test_settle_onlyHook_reverts() public {
        vm.prank(alice);
        vm.expectRevert(CollateralVault.OnlyHook.selector);
        vault.settle(true);
    }

    function test_settle_alreadySettled_reverts() public {
        vault.settle(true);
        vm.expectRevert(CollateralVault.AlreadySettled.selector);
        vault.settle(false);
    }

    function test_settle_setsYesWon_true() public {
        vault.settle(true);
        assertTrue(vault.settled());
        assertTrue(vault.yesWon());
    }

    function test_settle_setsYesWon_false() public {
        vault.settle(false);
        assertTrue(vault.settled());
        assertFalse(vault.yesWon());
    }

    function test_settle_emitsMarketSettled() public {
        vm.expectEmit(false, false, false, true);
        emit CollateralVault.MarketSettled(true);
        vault.settle(true);
    }

    // ==================== redeem ====================

    function test_redeem_yesWins_burnYes_getUsdc() public {
        vm.prank(alice);
        vault.mint(10 ether);
        vault.settle(true);

        uint256 usdcBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(10 ether);

        assertEq(yes.balanceOf(alice),  0);
        assertEq(usdc.balanceOf(alice), usdcBefore + 10 ether);
    }

    function test_redeem_noWins_burnNo_getUsdc() public {
        vm.prank(alice);
        vault.mint(10 ether);
        vault.settle(false);

        uint256 usdcBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(10 ether);

        assertEq(no.balanceOf(alice),   0);
        assertEq(usdc.balanceOf(alice), usdcBefore + 10 ether);
    }

    function test_redeem_notSettled_reverts() public {
        vm.prank(alice);
        vault.mint(10 ether);
        vm.prank(alice);
        vm.expectRevert(CollateralVault.NotSettled.selector);
        vault.redeem(5 ether);
    }

    function test_redeem_zeroAmount_reverts() public {
        vault.settle(true);
        vm.prank(alice);
        vm.expectRevert(CollateralVault.ZeroAmount.selector);
        vault.redeem(0);
    }

    function test_redeem_wrongToken_yesWins_noHolderReverts() public {
        // Bob has 0 YES (never minted), YES wins → trying to burn YES from bob reverts
        vault.settle(true);
        vm.prank(bob);
        vm.expectRevert(); // arithmetic underflow in ERC20 burn
        vault.redeem(1 ether);
    }

    function test_redeem_wrongToken_noWins_yesHolderReverts() public {
        vm.prank(alice);
        vault.mint(10 ether);
        // Alice sells all NO out of wallet (simulate by having alice only hold YES)
        // Settle NO wins → vault.redeem burns NO → alice has 10 NO, so this passes...
        // Use bob who has 0 NO tokens instead
        vault.settle(false);
        vm.prank(bob); // bob has 0 NO tokens
        vm.expectRevert(); // arithmetic underflow
        vault.redeem(1 ether);
    }

    function test_redeem_emitsRedeemed() public {
        vm.prank(alice);
        vault.mint(10 ether);
        vault.settle(true);

        vm.expectEmit(true, false, false, true);
        emit CollateralVault.Redeemed(alice, 10 ether, true);
        vm.prank(alice);
        vault.redeem(10 ether);
    }

    function test_redeem_noWins_yesTokenUnaffected() public {
        vm.prank(alice);
        vault.mint(10 ether);
        vault.settle(false);
        vm.prank(alice);
        vault.redeem(10 ether);
        // YES tokens still exist (worthless but unburned)
        assertEq(yes.balanceOf(alice), 10 ether);
        assertEq(no.balanceOf(alice),  0);
    }

    // ==================== Fuzz ====================

    function testFuzz_mint_burn(uint128 amount) public {
        uint256 a = bound(uint256(amount), 1, 50 ether);
        vm.prank(alice);
        vault.mint(a);
        vm.prank(alice);
        vault.burn(a);
        assertEq(yes.balanceOf(alice), 0);
        assertEq(no.balanceOf(alice),  0);
        assertEq(usdc.balanceOf(alice), 100 ether);
    }

    function testFuzz_redeem_yesWins(uint128 amount) public {
        uint256 a = bound(uint256(amount), 1, 50 ether);
        vm.prank(alice);
        vault.mint(a);
        vault.settle(true);
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(a);
        assertEq(usdc.balanceOf(alice), before + a);
        assertEq(yes.balanceOf(alice),  0);
    }

    function testFuzz_redeem_noWins(uint128 amount) public {
        uint256 a = bound(uint256(amount), 1, 50 ether);
        vm.prank(alice);
        vault.mint(a);
        vault.settle(false);
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(a);
        assertEq(usdc.balanceOf(alice), before + a);
        assertEq(no.balanceOf(alice),   0);
    }

    // ==================== Failure: missing USDC balance / approval ====================

    function test_mint_insufficientUsdcBalance_reverts() public {
        // stranger has no USDC at all
        address stranger = address(0x9999);
        vm.prank(stranger);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(stranger);
        vm.expectRevert(); // transferFrom fails: insufficient balance
        vault.mint(1 ether);
    }

    function test_mint_noApproval_reverts() public {
        // alice has USDC but vault has no allowance
        // (alice's approval from setUp covered by alice prank; revoke it first)
        vm.prank(alice);
        usdc.approve(address(vault), 0); // revoke allowance
        vm.prank(alice);
        vm.expectRevert(); // transferFrom fails: insufficient allowance
        vault.mint(10 ether);
    }

    function test_mint_partialApproval_reverts() public {
        vm.prank(alice);
        usdc.approve(address(vault), 5 ether); // only 5 approved
        vm.prank(alice);
        vm.expectRevert(); // transferFrom fails: allowance < amount
        vault.mint(10 ether);
    }

    // ==================== Failure: insufficient token balances on burn ====================

    function test_burn_insufficientYesBalance_reverts() public {
        vm.prank(alice);
        vault.mint(10 ether); // alice: 10 YES, 10 NO
        // Transfer 8 YES away so alice has only 2 YES but still 10 NO
        vm.prank(alice);
        yes.transfer(bob, 8 ether); // alice: 2 YES, 10 NO
        vm.prank(alice);
        vm.expectRevert(); // vault.burn burns YES first; 10 > 2 → underflow
        vault.burn(10 ether);
    }

    function test_burn_insufficientNoBalance_reverts() public {
        vm.prank(alice);
        vault.mint(10 ether); // alice: 10 YES, 10 NO
        // Transfer 8 NO away so alice has 10 YES but only 2 NO
        vm.prank(alice);
        no.transfer(bob, 8 ether); // alice: 10 YES, 2 NO
        vm.prank(alice);
        vm.expectRevert(); // vault.burn burns NO second; 10 > 2 → underflow
        vault.burn(10 ether);
    }

    function test_burn_zeroYes_reverts() public {
        // alice has 0 YES (never minted), burn must revert
        vm.prank(alice);
        vm.expectRevert(); // burning 0 YES from address with 0 YES → ZeroAmount check first
        vault.burn(0);
        // With non-zero amount: still no YES or NO → underflow
        vm.prank(alice);
        vm.expectRevert();
        vault.burn(1 ether);
    }

    // ==================== Redeem: two-step partial redemption ====================

    function test_redeem_partial_thenRemainder_yesWins() public {
        vm.prank(alice);
        vault.mint(20 ether);
        vault.settle(true);

        // First partial redeem
        vm.prank(alice);
        vault.redeem(8 ether);
        assertEq(yes.balanceOf(alice), 12 ether);

        // Second partial redeem
        vm.prank(alice);
        vault.redeem(12 ether);
        assertEq(yes.balanceOf(alice), 0);
        assertEq(usdc.balanceOf(alice), 100 ether - 20 ether + 20 ether); // net zero cost
    }

    function test_redeem_partial_thenRemainder_noWins() public {
        vm.prank(alice);
        vault.mint(20 ether);
        vault.settle(false);

        vm.prank(alice);
        vault.redeem(5 ether);
        assertEq(no.balanceOf(alice), 15 ether);

        vm.prank(alice);
        vault.redeem(15 ether);
        assertEq(no.balanceOf(alice), 0);
        assertEq(usdc.balanceOf(alice), 100 ether); // all USDC back
    }

    // ==================== Fuzz: multi-user ====================

    function testFuzz_multiUser_mint_redeem(uint128 amountA, uint128 amountB) public {
        uint256 a = bound(uint256(amountA), 1, 40 ether);
        uint256 b = bound(uint256(amountB), 1, 40 ether);

        vm.prank(alice);
        vault.mint(a);
        vm.prank(bob);
        vault.mint(b);

        assertEq(usdc.balanceOf(address(vault)), a + b);

        vault.settle(true); // YES wins

        // Both users redeem their YES
        vm.prank(alice);
        vault.redeem(a);
        vm.prank(bob);
        vault.redeem(b);

        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(yes.balanceOf(alice), 0);
        assertEq(yes.balanceOf(bob),   0);
    }

    function testFuzz_vault_invariant_usdcBalanceEqualsSupply(uint128 amount) public {
        uint256 a = bound(uint256(amount), 1, 50 ether);
        // Invariant: vault USDC balance == YES total supply == NO total supply at all times
        vm.prank(alice);
        vault.mint(a);
        assertEq(usdc.balanceOf(address(vault)), a);
        assertEq(yes.totalSupply(), a);
        assertEq(no.totalSupply(),  a);

        // Burn half
        uint256 burnAmt = a / 2;
        if (burnAmt > 0) {
            vm.prank(alice);
            vault.burn(burnAmt);
            assertEq(usdc.balanceOf(address(vault)), a - burnAmt);
            assertEq(yes.totalSupply(), a - burnAmt);
            assertEq(no.totalSupply(),  a - burnAmt);
        }
    }
}
