// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import {Test} from "forge-std/Test.sol";
import {EpochFrequency} from "../src/lib/EpochFrequency.sol";
import {TestnetToken} from "../src/testnet/TestnetToken.sol";
import {TestnetPriceOracle} from "../src/testnet/TestnetPriceOracle.sol";
import {TestnetRegistry} from "../src/testnet/TestnetRegistry.sol";
import {Utils} from "./utils/Utils.sol";
import {VaultUtils} from "./utils/VaultUtils.sol";
import {MockedIG} from "./mock/MockedIG.sol";
import {MockedVault} from "./mock/MockedVault.sol";
import {AddressProvider} from "../src/AddressProvider.sol";

contract RegistryTest is Test {
    bytes4 constant MissingAddress = bytes4(keccak256("MissingAddress()"));
    TestnetRegistry registry;
    MockedIG dvp;
    address admin = address(0x21);
    AddressProvider ap;

    constructor() {

        vm.startPrank(admin);
        ap = new AddressProvider();
        registry = new TestnetRegistry();
        ap.setRegistry(address(registry));

        vm.stopPrank();

        MockedVault vault = MockedVault(VaultUtils.createVault(EpochFrequency.DAILY, ap, admin, vm));
        dvp = new MockedIG(address(vault), address(ap));
    }

    function testNotRegisteredAddress() public {
        address addrToCheck = address(0x150);
        bool isAddressRegistered = registry.isRegistered(addrToCheck);
        assertEq(false, isAddressRegistered);
    }

    function testRegisterAddress() public {
        address addrToRegister = address(dvp);

        bool isAddressRegistered = registry.isRegistered(addrToRegister);
        assertEq(false, isAddressRegistered);

        vm.prank(admin);
        registry.register(addrToRegister);

        isAddressRegistered = registry.isRegistered(addrToRegister);
        assertEq(true, isAddressRegistered);
    }

    function testUnregisterAddressFail() public {
        address addrToUnregister = address(0x150);
        vm.expectRevert(MissingAddress);
        vm.prank(admin);
        registry.unregister(addrToUnregister);
    }

    function testUnregisterAddress() public {
        address addrToUnregister = address(dvp);

        vm.prank(admin);
        registry.register(addrToUnregister);
        bool isAddressRegistered = registry.isRegistered(addrToUnregister);
        assertEq(true, isAddressRegistered);

        vm.prank(admin);
        registry.unregister(addrToUnregister);

        isAddressRegistered = registry.isRegistered(addrToUnregister);
        assertEq(false, isAddressRegistered);
    }

    function testSideTokenIndexing() public {
        address dvpAddr = address(dvp);
        vm.prank(admin);
        registry.register(dvpAddr);

        address tokenAddr = dvp.sideToken();
        address[] memory tokens = registry.getSideTokens();
        address[] memory dvps = registry.getDvpsBySideToken(tokenAddr);

        assertEq(1, tokens.length);
        assertEq(tokenAddr, tokens[0]);

        assertEq(1, dvps.length);
        assertEq(dvpAddr, dvps[0]);

        vm.prank(admin);
        registry.unregister(dvpAddr);

        tokens = registry.getSideTokens();
        dvps = registry.getDvpsBySideToken(tokenAddr);

        assertEq(0, tokens.length);
        assertEq(0, dvps.length);
    }

    function testSideTokenIndexingDup() public {
        address dvpAddr = address(dvp);
        vm.prank(admin);
        registry.register(dvpAddr);

        vm.prank(admin);
        registry.register(dvpAddr);

        address tokenAddr = dvp.sideToken();
        address[] memory tokens = registry.getSideTokens();
        address[] memory dvps = registry.getDvpsBySideToken(tokenAddr);

        assertEq(1, tokens.length);
        assertEq(tokenAddr, tokens[0]);

        assertEq(1, dvps.length);
        assertEq(dvpAddr, dvps[0]);
    }

    function testMultiSideTokenIndexing() public {
        MockedVault vault2 = MockedVault(VaultUtils.createVaultSideTokenSym(dvp.baseToken(), "JOE", 0, ap, admin, vm));
        MockedIG dvp2 = new MockedIG(address(vault2), address(ap));

        vm.prank(admin);
        registry.register(address(dvp));

        vm.prank(admin);
        registry.register(address(dvp2));

        address[] memory tokens = registry.getSideTokens();
        assertEq(2, tokens.length);
        assertEq(dvp.sideToken(), tokens[0]);
        assertEq(dvp2.sideToken(), tokens[1]);

        address[] memory dvps = registry.getDvpsBySideToken(dvp.sideToken());
        assertEq(1, dvps.length);
        assertEq(address(dvp), dvps[0]);

        dvps = registry.getDvpsBySideToken(dvp2.sideToken());
        assertEq(1, dvps.length);
        assertEq(address(dvp2), dvps[0]);

        vm.prank(admin);
        registry.unregister(address(dvp));

        tokens = registry.getSideTokens();
        assertEq(1, tokens.length);
        assertEq(dvp2.sideToken(), tokens[0]);

        dvps = registry.getDvpsBySideToken(dvp.sideToken());
        assertEq(0, dvps.length);

        dvps = registry.getDvpsBySideToken(dvp2.sideToken());
        assertEq(1, dvps.length);
        assertEq(address(dvp2), dvps[0]);
    }

    function testDVPToRoll() public {
        vm.startPrank(admin);
        MockedVault(dvp.vault()).setAllowedDVP(address(dvp));
        vm.stopPrank();

        vm.warp(EpochFrequency.REF_TS);
        dvp.rollEpoch();

        Utils.skipDay(true, vm);

        MockedVault vault2 = MockedVault(VaultUtils.createVault(EpochFrequency.DAILY, ap, admin, vm));
        MockedIG dvp2 = new MockedIG(address(vault2), address(ap));

        TestnetPriceOracle po = TestnetPriceOracle(ap.priceOracle());

        vm.startPrank(admin);
        registry.register(address(dvp));
        registry.register(address(dvp2));
        vault2.setAllowedDVP(address(dvp2));
        po.setTokenPrice(vault2.baseToken(), 1e18);
        vm.stopPrank();

        dvp2.rollEpoch();

        uint256 timeToNextEpochDvp = dvp.timeToNextEpoch();
        uint256 timeToNextEpochDvp2 = dvp2.timeToNextEpoch();

        assertEq(0, timeToNextEpochDvp);
        assertApproxEqAbs(86400, timeToNextEpochDvp2, 10);

        (address[] memory dvps, uint256 dvpsToRoll) = registry.getUnrolledDVPs();

        assertEq(1, dvpsToRoll);
        assertEq(keccak256(abi.encodePacked(dvps)), keccak256(abi.encodePacked([address(dvp), address(0)])));

        dvp.rollEpoch();

        (dvps, dvpsToRoll) = registry.getUnrolledDVPs();

        assertEq(0, dvpsToRoll);
        assertEq(keccak256(abi.encodePacked(dvps)), keccak256(abi.encodePacked([address(0), address(0)])));
        Utils.skipDay(true, vm);

        (dvps, dvpsToRoll) = registry.getUnrolledDVPs();

        assertEq(2, dvpsToRoll);
        assertEq(keccak256(abi.encodePacked(dvps)), keccak256(abi.encodePacked([address(dvp), address(dvp2)])));
    }
}
