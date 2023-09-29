// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {TestnetToken} from "../src/testnet/TestnetToken.sol";
import {Factory} from "../src/Factory.sol";
import {EpochFrequency} from "../src/lib/EpochFrequency.sol";
import {DVP} from "../src/DVP.sol";
import {DVPType} from "../src/lib/DVPType.sol";
import {Registry} from "../src/Registry.sol";
import {Vault} from "../src/Vault.sol";
import {IG} from "../src/IG.sol";
import {AddressProvider} from "../src/AddressProvider.sol";
import {Epoch} from "../src/lib/EpochController.sol";

contract FactoryTest is Test {
    bytes4 constant AddressZero = bytes4(keccak256("AddressZero()"));

    address tokenAdmin = address(0x1);

    TestnetToken baseToken;
    TestnetToken sideToken;
    uint256 epochFrequency;
    Registry registry;
    Factory factory;

    function setUp() public {
        vm.startPrank(tokenAdmin);
        AddressProvider ap = new AddressProvider();
        ap.grantRole(ap.ROLE_ADMIN(), tokenAdmin);
        vm.stopPrank();

        vm.startPrank(tokenAdmin);
        registry = new Registry();

        ap.setRegistry(address(registry));
        ap.setExchangeAdapter(address(0x5));

        TestnetToken token = new TestnetToken("Testnet USD", "stUSD");
        token.setAddressProvider(address(ap));
        baseToken = token;

        token = new TestnetToken("Testnet WETH", "stWETH");
        token.setAddressProvider(address(ap));
        sideToken = token;

        factory = new Factory(address(ap));
        registry.grantRole(registry.ADMIN_ROLE(), address(factory));

        vm.stopPrank();

        vm.warp(EpochFrequency.REF_TS);
    }

    function testFactoryUnauthorized() public {
        //vm.startPrank(address(0x100));
        vm.expectRevert("Ownable: caller is not the owner");
        factory.createIGMarket(address(baseToken), address(sideToken), EpochFrequency.DAILY);
    }

    function testFactoryTokenBaseTokenZero() public {
        vm.prank(tokenAdmin);
        vm.expectRevert(AddressZero);
        factory.createIGMarket(address(0x0), address(sideToken), EpochFrequency.DAILY);
    }

    function testFactoryTokenSideTokenZero() public {
        vm.prank(tokenAdmin);
        vm.expectRevert(AddressZero);
        factory.createIGMarket(address(baseToken), address(0x0), EpochFrequency.DAILY);
    }

    function testFactoryCreatedDVP() public {
        vm.startPrank(tokenAdmin);
        address dvp = factory.createIGMarket(address(baseToken), address(sideToken), EpochFrequency.DAILY);
        DVP igDVP = DVP(dvp);

        assertEq(igDVP.baseToken(), address(baseToken));
        assertEq(igDVP.sideToken(), address(sideToken));
        assertEq(igDVP.optionType(), DVPType.IG);
        Epoch memory epoch = igDVP.getEpoch();
        assertEq(epoch.frequency, EpochFrequency.DAILY);
    }

    function testFactoryCreatedVault() public {
        vm.startPrank(tokenAdmin);
        address dvp = factory.createIGMarket(address(baseToken), address(sideToken), EpochFrequency.DAILY);
        DVP igDVP = DVP(dvp);
        Vault vault = Vault(igDVP.vault());

        assertEq(vault.baseToken(), address(baseToken));
        assertEq(vault.sideToken(), address(sideToken));
        Epoch memory epoch = vault.getEpoch();
        assertEq(epoch.frequency, EpochFrequency.DAILY);
    }
}
