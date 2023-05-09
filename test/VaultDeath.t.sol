// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IDVP} from "../src/interfaces/IDVP.sol";
import {IG} from "../src/IG.sol";
import {EpochFrequency} from "../src/lib/EpochFrequency.sol";
import {TestnetToken} from "../src/testnet/TestnetToken.sol";
import {Vault} from "../src/Vault.sol";
import {TokenUtils} from "./utils/TokenUtils.sol";
import {Utils} from "./utils/Utils.sol";
import {VaultLib} from "../src/lib/VaultLib.sol";
import {VaultUtils} from "./utils/VaultUtils.sol";
import {Registry} from "../src/Registry.sol";

contract VaultDeathTest is Test {
    bytes4 constant VaultDead = bytes4(keccak256("VaultDead()"));
    bytes4 constant VaultNotDead = bytes4(keccak256("VaultNotDead()"));

    address tokenAdmin = address(0x1);
    address alice = address(0x2);
    address bob = address(0x3);
    TestnetToken baseToken;
    TestnetToken sideToken;
    Registry registry;
    Vault vault;

    function setUp() public {
        registry = new Registry();
        address controller = address(registry);
        address swapper = address(0x5);
        vm.startPrank(tokenAdmin);

        TestnetToken token = new TestnetToken("Testnet USD", "stUSD");
        token.setController(controller);
        token.setSwapper(swapper);
        baseToken = token;

        token = new TestnetToken("Testnet WETH", "stWETH");
        token.setController(controller);
        token.setSwapper(swapper);
        sideToken = token;

        vm.stopPrank();
        vm.warp(EpochFrequency.REF_TS);

        vault = VaultUtils.createMarket(address(baseToken), address(sideToken), EpochFrequency.DAILY, registry);
    }

    /**
     * Describe two users, the first (Alice) deposits 100$ in epoch1 receiving 100 shares.
     * Bob deposits 100$ in epoch2. Bob receive also 100 shares.
     * Bob and Alice starts the withdraw procedure in epoch3. Meanwhile, the lockedLiquidity goes to 0.
     * In epoch3, the Vault dies due to empty lockedLiquidity (so the sharePrice is 0). Nobody can deposit from epoch2 on.
     * Bob and Alice could complete the withdraw procedure receiving both 0$.
     */
    function testVaultMathLiquidityGoesToZero() public {
        vault.rollEpoch();

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

        assertEq(0, baseToken.balanceOf(address(vault)));

        Utils.skipDay(false, vm);
        vault.rollEpoch();

        assertEq(true, VaultUtils.vaultState(vault).dead);

        vm.startPrank(alice);
        vault.completeWithdraw();

        (, uint256 withdrawalSharesAlice) = vault.withdrawals(alice);
        assertEq(100, vault.totalSupply());
        assertEq(0, baseToken.balanceOf(address(vault)));
        assertEq(0, baseToken.balanceOf(address(alice)));
        assertEq(0, withdrawalSharesAlice);
        vm.stopPrank();

        vm.startPrank(bob);
        vault.completeWithdraw();

        (, uint256 withdrawalSharesBob) = vault.withdrawals(bob);
        assertEq(0, vault.totalSupply());
        assertEq(0, baseToken.balanceOf(address(vault)));
        assertEq(0, baseToken.balanceOf(address(bob)));
        assertEq(0, withdrawalSharesBob);
        vm.stopPrank();
    }

    /**
     * Describe the case of deposit after Vault Death. In this case is expected an error.
     */
    function testVaultMathLiquidityGoesToZeroWithDepositAfterDieFail() public {
        vault.rollEpoch();

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

        assertEq(0, baseToken.balanceOf(address(vault)));

        Utils.skipDay(false, vm);
        vault.rollEpoch();

        // Check if lockedLiquidity has gone to 0 and the Vault is dead.
        assertEq(0, VaultUtils.vaultState(vault).liquidity.locked);
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
        vault.rollEpoch();

        TokenUtils.provideApprovedTokens(tokenAdmin, address(baseToken), alice, address(vault), 200, vm);

        vm.startPrank(alice);
        vault.deposit(100);
        vm.stopPrank();
        Utils.skipDay(true, vm);

        vault.rollEpoch();

        (uint256 heldByAccountAlice, uint256 heldByVaultAlice) = vault.shareBalances(alice);
        assertEq(100, vault.totalSupply());
        assertEq(100, heldByVaultAlice);

        Utils.skipDay(false, vm);
        vault.rollEpoch();

        vault.moveAsset(-100);

        assertEq(0, baseToken.balanceOf(address(vault)));

        vm.startPrank(alice);
        vault.deposit(100);
        vm.stopPrank();

        Utils.skipDay(false, vm);
        vault.rollEpoch();

        assertEq(100, vault.totalSupply());

        // Check if lockedLiquidity has gone to 0 and the Vault is dead.
        assertEq(0, VaultUtils.vaultState(vault).liquidity.locked);
        assertEq(true, VaultUtils.vaultState(vault).dead);

        (heldByAccountAlice, heldByVaultAlice) = vault.shareBalances(alice);

        assertEq(0, heldByAccountAlice);
        assertEq(100, heldByVaultAlice);

        assertEq(100, baseToken.balanceOf(address(vault)));
        (, uint256 depositReceiptsAliceAmount, ) = vault.depositReceipts(alice);
        assertEq(100, depositReceiptsAliceAmount);

        // Alice rescues her baseToken
        vm.startPrank(alice);
        vault.rescueDeposit();
        vm.stopPrank();

        assertEq(0, baseToken.balanceOf(address(vault)));
        assertEq(100, baseToken.balanceOf(alice));
        (, depositReceiptsAliceAmount, ) = vault.depositReceipts(alice);
        assertEq(0, depositReceiptsAliceAmount);
    }

    /**
     *
     */
    function testVaultRescueDepositVaultNotDeath() public {
        vault.rollEpoch();

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
}
