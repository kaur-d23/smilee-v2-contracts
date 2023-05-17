// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import {Test} from "forge-std/Test.sol";
import {EpochFrequency} from "../src/lib/EpochFrequency.sol";
import {TestnetToken} from "../src/testnet/TestnetToken.sol";
import {Vault} from "../src/Vault.sol";
import {TokenUtils} from "./utils/TokenUtils.sol";
import {Utils} from "./utils/Utils.sol";
import {VaultUtils} from "./utils/VaultUtils.sol";

/**
    @title Test case for underlying asset going to zero
    @dev This should never happen, still we need to test shares value goes to zero, users deposits can be rescued and
         new deposits are not allowed
 */
contract VaultDeathTest is Test {
    bytes4 constant NothingToRescue = bytes4(keccak256("NothingToRescue()"));
    bytes4 constant VaultDead = bytes4(keccak256("VaultDead()"));
    bytes4 constant VaultNotDead = bytes4(keccak256("VaultNotDead()"));

    address tokenAdmin = address(0x1);
    address alice = address(0x2);
    address bob = address(0x3);
    TestnetToken baseToken;
    TestnetToken sideToken;
    Vault vault;

    function setUp() public {
        vm.warp(EpochFrequency.REF_TS);

        vault = VaultUtils.createVaultFromNothing(EpochFrequency.DAILY, tokenAdmin, vm);
        baseToken = TestnetToken(vault.baseToken());
        sideToken = TestnetToken(vault.sideToken());

        vault.rollEpoch();
    }

    /**
     * Describe two users, the first (Alice) deposits 100$ in epoch1 receiving 100 shares.
     * Bob deposits 100$ in epoch2. Bob receive also 100 shares.
     * Bob and Alice starts the withdraw procedure in epoch3. Meanwhile, the lockedLiquidity goes to 0.
     * In epoch3, the Vault dies due to empty lockedLiquidity (so the sharePrice is 0). Nobody can deposit from epoch2 on.
     * Bob and Alice could complete the withdraw procedure receiving both 0$.
     */
    function testVaultMathLiquidityGoesToZero() public {
        TokenUtils.provideApprovedTokens(tokenAdmin, address(baseToken), alice, address(vault), 100, vm);
        TokenUtils.provideApprovedTokens(tokenAdmin, address(baseToken), bob, address(vault), 100, vm);

        vm.startPrank(alice);
        vault.deposit(100);
        vm.stopPrank();
        Utils.skipDay(true, vm);

        vault.rollEpoch();

        (, uint256 heldByVaultAlice) = vault.shareBalances(alice);
        assertEq(100, vault.totalSupply());
        assertEq(100, heldByVaultAlice);

        vm.startPrank(bob);
        vault.deposit(100);
        vm.stopPrank();
        Utils.skipDay(false, vm);

        vault.rollEpoch();

        (, uint256 heldByVaultBob) = vault.shareBalances(bob);
        assertEq(200, vault.totalSupply());
        assertEq(100, heldByVaultBob);

        vm.startPrank(alice);
        vault.initiateWithdraw(100);
        vm.stopPrank();

        vm.startPrank(bob);
        vault.initiateWithdraw(100);
        vm.stopPrank();

        vault.moveAsset(-200);

        assertEq(0, vault.getLockedValue());

        Utils.skipDay(false, vm);
        vault.rollEpoch();

        assertEq(true, VaultUtils.vaultState(vault).dead);

        vm.startPrank(alice);
        vault.completeWithdraw();

        (, uint256 withdrawalSharesAlice) = vault.withdrawals(alice);
        assertEq(100, vault.totalSupply());
        assertEq(0, vault.getLockedValue());
        assertEq(0, baseToken.balanceOf(address(alice)));
        assertEq(0, withdrawalSharesAlice);
        vm.stopPrank();

        vm.startPrank(bob);
        vault.completeWithdraw();

        (, uint256 withdrawalSharesBob) = vault.withdrawals(bob);
        assertEq(0, vault.totalSupply());
        assertEq(0, vault.getLockedValue());
        assertEq(0, baseToken.balanceOf(address(bob)));
        assertEq(0, withdrawalSharesBob);
        vm.stopPrank();
    }

    /**
     * Describe the case of deposit after Vault Death. In this case is expected an error.
     */
    function testVaultMathLiquidityGoesToZeroWithDepositAfterDieFail() public {
        TokenUtils.provideApprovedTokens(tokenAdmin, address(baseToken), alice, address(vault), 200, vm);

        vm.startPrank(alice);
        vault.deposit(100);
        vm.stopPrank();
        Utils.skipDay(true, vm);

        vault.rollEpoch();

        (, uint256 heldByVaultAlice) = vault.shareBalances(alice);
        assertEq(100, vault.totalSupply());
        assertEq(100, heldByVaultAlice);

        Utils.skipDay(false, vm);
        vault.rollEpoch();

        vault.moveAsset(-100);

        assertEq(0, vault.getLockedValue());

        Utils.skipDay(false, vm);
        vault.rollEpoch();

        // Check if lockedLiquidity has gone to 0 and the Vault is dead.
        assertEq(0, vault.getLockedValue());
        assertEq(true, VaultUtils.vaultState(vault).dead);

        // Alice wants to deposit after Vault death. We expect a VaultDead error.
        vm.startPrank(alice);
        vm.expectRevert(VaultDead);
        vault.deposit(100);
        vm.stopPrank();
    }

    /**
     *
     */
    function testVaultMathLiquidityGoesToZeroWithDepositBeforeDie() public {
        TokenUtils.provideApprovedTokens(tokenAdmin, address(baseToken), alice, address(vault), 200, vm);

        vm.prank(alice);
        vault.deposit(100);

        Utils.skipDay(true, vm);
        vault.rollEpoch();

        (uint256 heldByAccountAlice, uint256 heldByVaultAlice) = vault.shareBalances(alice);
        assertEq(100, vault.totalSupply());
        assertEq(100, heldByVaultAlice);

        Utils.skipDay(false, vm);
        vault.rollEpoch();

        // NOTE: cause the locked liquidity to go to zero; this, in turn, cause the vault death
        vault.moveAsset(-100);
        assertEq(0, VaultUtils.vaultState(vault).liquidity.locked);
        assertEq(0, vault.getLockedValue());

        vm.prank(alice);
        vault.deposit(100);

        Utils.skipDay(false, vm);
        vault.rollEpoch();

        assertEq(true, VaultUtils.vaultState(vault).dead);
        // No new shares has been minted:
        assertEq(100, vault.totalSupply());
        // Locked liquidity is still zero:
        assertEq(0, VaultUtils.vaultState(vault).liquidity.locked);

        (heldByAccountAlice, heldByVaultAlice) = vault.shareBalances(alice);
        assertEq(0, heldByAccountAlice);
        assertEq(100, heldByVaultAlice);

        assertEq(100, VaultUtils.getRecoverableAmounts(vault));

        (, uint256 depositReceiptsAliceAmount, ) = vault.depositReceipts(alice);
        assertEq(100, depositReceiptsAliceAmount);

        // Alice rescues her baseToken
        vm.prank(alice);
        vault.rescueDeposit();

        assertEq(0, VaultUtils.getRecoverableAmounts(vault));
        assertEq(0, baseToken.balanceOf(address(vault)));
        assertEq(100, baseToken.balanceOf(alice));
        (, depositReceiptsAliceAmount, ) = vault.depositReceipts(alice);
        assertEq(0, depositReceiptsAliceAmount);
    }

    function testVaultRescueDepositVaultNotDeath() public {
        TokenUtils.provideApprovedTokens(tokenAdmin, address(baseToken), alice, address(vault), 200, vm);

        vm.startPrank(alice);
        vault.deposit(100);
        vm.expectRevert(VaultNotDead);
        vault.rescueDeposit();
        vm.stopPrank();
        Utils.skipDay(true, vm);

        vault.rollEpoch();

        (, uint256 heldByVaultAlice) = vault.shareBalances(alice);
        assertEq(100, vault.totalSupply());
        assertEq(100, heldByVaultAlice);

        Utils.skipDay(false, vm);
        vault.rollEpoch();
    }

    /**
     * An user tries to call rescueDeposit function when a vault is dead, but without nothing to rescue. A NothingToRescue error is expected.
     */
    function testVaultRescueDepositNothingToRescue() public {
        TokenUtils.provideApprovedTokens(tokenAdmin, address(baseToken), alice, address(vault), 100, vm);

        vm.prank(alice);
        vault.deposit(100);
        Utils.skipDay(true, vm);

        vault.rollEpoch();

        (, uint256 heldByVaultAlice) = vault.shareBalances(alice);
        assertEq(100, vault.totalSupply());
        assertEq(100, heldByVaultAlice);

        vault.moveAsset(-100);

        assertEq(0, vault.getLockedValue());

        Utils.skipDay(false, vm);
        vault.rollEpoch();

        assertEq(100, vault.totalSupply());

        // Check if lockedLiquidity has gone to 0 and the Vault is dead.
        assertEq(0, vault.getLockedValue());
        assertEq(true, VaultUtils.vaultState(vault).dead);

        //Alice starts the rescue procedure. An error is expected
        vm.prank(alice);
        vm.expectRevert(NothingToRescue);
        vault.rescueDeposit();
    }
}
