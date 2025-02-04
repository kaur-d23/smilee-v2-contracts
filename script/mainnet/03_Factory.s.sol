// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import {console} from "forge-std/console.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IRegistry} from "@project/interfaces/IRegistry.sol";
import {TimeLockedFinanceParameters, TimeLockedFinanceValues} from "@project/lib/FinanceIG.sol";
import {TimeLock, TimeLockedBool, TimeLockedUInt} from "@project/lib/TimeLock.sol";
import {AddressProvider} from "@project/AddressProvider.sol";
import {FeeManager} from "@project/FeeManager.sol";
import {IG} from "@project/IG.sol";
import {Vault} from "@project/Vault.sol";
import {ChainlinkPriceOracle} from "@project/providers/chainlink/ChainlinkPriceOracle.sol";
import {SwapAdapterRouter} from "@project/providers/SwapAdapterRouter.sol";
import {EnhancedScript} from "../utils/EnhancedScript.sol";

/*
    Reference: https://book.getfoundry.sh/tutorials/solidity-scripting
    ToDo: see https://book.getfoundry.sh/tutorials/best-practices#scripts

    Usage:
        source .env

        # To deploy [and verify] the contracts
        # - On a real network:
        #   ToDo: see https://book.getfoundry.sh/reference/forge/forge-script#wallet-options---raw
        forge script script/mainnet/03_Factory.s.sol:DeployDVP --rpc-url $RPC_MAINNET --broadcast [--verify] -vvvv

        # NOTE: add the following to customize
        #       --sig 'createIGMarket(address,address,uint256,uint256)' <BASE_TOKEN_ADDRESS> <SIDE_TOKEN_ADDRESS> <EPOCH_FREQUENCY_IN_SECONDS> <FIRST_EPOCH_DURATION_IN_SECONDS>
 */
contract DeployDVP is EnhancedScript {
    using TimeLock for TimeLockedBool;
    using TimeLock for TimeLockedUInt;

    address internal _deployerAddress;
    uint256 internal _deployerPrivateKey;
    address internal _adminAddress;
    uint256 internal _adminPrivateKey;

    address internal _godAddress;
    address internal _scheduler;

    bool internal _deployerIsGod;
    bool internal _deployerIsAdmin;

    AddressProvider internal _addressProvider;
    FeeManager internal _feeManager;
    IRegistry internal _registry;

    address internal _dvpAddr;
    address internal _vaultAddr;

    constructor() {
        // Load the private key that will be used for signing the transactions:
        _deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        _deployerAddress = vm.envAddress("DEPLOYER_ADDRESS");

        _adminAddress = vm.envAddress("ADMIN_ADDRESS");
        _adminPrivateKey = vm.envUint("ADMIN_PRIVATE_KEY");

        _godAddress = vm.envAddress("GOD_ADDRESS");
        _scheduler = vm.envAddress("EPOCH_ROLLER_ADDRESS");

        _deployerIsGod = (_deployerAddress == _godAddress);
        _deployerIsAdmin = (_deployerAddress == _adminAddress);

        string memory txLogs = _getLatestTransactionLogs("01_CoreFoundations.s.sol");

        _addressProvider = AddressProvider(_readAddress(txLogs, "AddressProvider"));
        _checkZeroAddress(address(_addressProvider), "AddressProvider");
        _checkZeroAddress(_addressProvider.feeManager(), "FeeManager");
        _feeManager = FeeManager(_addressProvider.feeManager());
        _checkZeroAddress(_addressProvider.registry(), "IRegistry");
        _registry = IRegistry(_addressProvider.registry());
    }

    function run() external view {
        console.log("Please run a specific task");
    }

    function createIGMarket(
        address baseToken,
        address sideToken,
        uint256 epochFrequency,
        uint256 firstEpochDuration
    ) public {
        vm.startBroadcast(_deployerPrivateKey);

        _checkZeroAddress(_addressProvider.priceOracle(), "ChainlinkPriceOracle");
        ChainlinkPriceOracle priceOracle = ChainlinkPriceOracle(_addressProvider.priceOracle());
        _checkZeroAddress(_addressProvider.exchangeAdapter(), "SwapAdapterRouter");
        SwapAdapterRouter swapAdapter = SwapAdapterRouter(_addressProvider.exchangeAdapter());

        _checkZeroAddress(_deployerAddress, "DEPLOYER_ADDRESS");
        _checkZeroAddress(_godAddress, "GOD_ADDRESS");
        _checkZeroAddress(_adminAddress, "ADMIN_ADDRESS");
        _checkZeroAddress(_scheduler, "EPOCH_ROLLER_ADDRESS");

        // Check if exists a record for the given tokens
        priceOracle.getPrice(baseToken, sideToken);
        if (swapAdapter.getAdapter(baseToken, sideToken) == address(0)) {
            revert("Swap Adapter hasn't been set for the tokens pair (1)");
        }
        if (swapAdapter.getAdapter(sideToken, baseToken) == address(0)) {
            revert("Swap Adapter hasn't been set for the tokens pair (2)");
        }

        //----------------

        address vaultAddr = _createVault(baseToken, sideToken, epochFrequency, firstEpochDuration);
        address dvpAddr = _createImpermanentGainDVP(vaultAddr);

        Vault vault = Vault(vaultAddr);

        vault.setAllowedDVP(dvpAddr);
        vault.setPriorityAccessFlag(true);
        if (!_deployerIsAdmin) {
            vault.renounceRole(vault.ROLE_ADMIN(), _deployerAddress);
        }

        string memory sideTokenSymbol = IERC20Metadata(vault.sideToken()).symbol();
        // TODO: review to better handle wrapped tokens
        bool deribitToken = _stringEquals(sideTokenSymbol, "WETH") || _stringEquals(sideTokenSymbol, "WBTC");
        if (!deribitToken) {
            _useOnchainImpliedVolatility(dvpAddr);
        }
        if (!_deployerIsAdmin) {
            IG dvp = IG(dvpAddr);
            dvp.renounceRole(dvp.ROLE_ADMIN(), _deployerAddress);
        }

        vm.stopBroadcast();

        console.log("DVP deployed at", dvpAddr);
        console.log("Vault deployed at", vaultAddr);
        _dvpAddr = dvpAddr;
        _vaultAddr = vaultAddr;

        //----------------

        vm.startBroadcast(_adminPrivateKey);

        uint8 decimals = IERC20Metadata(baseToken).decimals();
        FeeManager.FeeParams memory feeParams = FeeManager.FeeParams({
            timeToExpiryThreshold: 3600,
            minFeeBeforeTimeThreshold: (10 ** decimals), // 1 dollaro
            minFeeAfterTimeThreshold: (10 ** decimals), // 1 dollaro
            successFeeTier: 0.005e18, // 0.5 %
            feePercentage: 0.0004e18, // 0.04 %
            capPercentage: 0.125e18, // 12.5 %
            maturityFeePercentage: 0.0004e18, // 0.04 %
            maturityCapPercentage: 0.125e18 // 12.5 %
        });

        _feeManager.setDVPFee(dvpAddr, feeParams);

        _registry.register(dvpAddr);

        vm.stopBroadcast();
    }

    function _stringEquals(string memory s1, string memory s2) internal pure returns (bool) {
        // TBD: use abi.encodePacked(s) instead of bytes(s)
        return keccak256(bytes(s1)) == keccak256(bytes(s2));
    }

    function _createVault(
        address baseToken,
        address sideToken,
        uint256 epochFrequency,
        uint256 firstEpochDuration
    ) internal returns (address) {
        Vault vault = new Vault(baseToken, sideToken, epochFrequency, firstEpochDuration, address(_addressProvider));

        vault.grantRole(vault.ROLE_GOD(), _godAddress);
        vault.grantRole(vault.ROLE_ADMIN(), _adminAddress);
        vault.grantRole(vault.ROLE_ADMIN(), _deployerAddress); // TMP for setAllowedDVP
        if (!_deployerIsGod) {
            vault.renounceRole(vault.ROLE_GOD(), _deployerAddress);
        }

        return address(vault);
    }

    function setDVPSuccessFee(address dvp, uint256 fee) public {
        vm.startBroadcast(_adminPrivateKey);
        (
            uint256 timeToExpiryThreshold,
            uint256 minFeeBeforeTimeThreshold,
            uint256 minFeeAfterTimeThreshold,
            ,
            uint256 feePercentage,
            uint256 capPercentage,
            uint256 maturityFeePercentage,
            uint256 maturityCapPercentage
        ) = _feeManager.dvpsFeeParams(dvp);
        FeeManager.FeeParams memory params = FeeManager.FeeParams({
            timeToExpiryThreshold: timeToExpiryThreshold,
            minFeeBeforeTimeThreshold: minFeeBeforeTimeThreshold,
            minFeeAfterTimeThreshold: minFeeAfterTimeThreshold,
            successFeeTier: fee,
            feePercentage: feePercentage,
            capPercentage: capPercentage,
            maturityFeePercentage: maturityFeePercentage,
            maturityCapPercentage: maturityCapPercentage
        });
        _feeManager.setDVPFee(dvp, params);
        vm.stopBroadcast();
    }

    function setDVPFee(
        address dvp,
        uint256 timeToExpiryThreshold,
        uint256 minFeeBeforeThreshold,
        uint256 minFeeAfterThreshold,
        uint256 successFeeTier,
        uint256 feePercentage,
        uint256 capPercertage,
        uint256 mFeePercentage,
        uint256 mCapPercentage
    ) public {
        FeeManager.FeeParams memory params = FeeManager.FeeParams(
            timeToExpiryThreshold,
            minFeeBeforeThreshold,
            minFeeAfterThreshold,
            successFeeTier,
            feePercentage,
            capPercertage,
            mFeePercentage,
            mCapPercentage
        );

        vm.startBroadcast(_adminPrivateKey);
        _feeManager.setDVPFee(dvp, params);
        vm.stopBroadcast();
    }

    function _createImpermanentGainDVP(address vault) internal returns (address) {
        address pm = _addressProvider.dvpPositionManager();

        IG dvp = new IG(vault, address(_addressProvider));

        dvp.grantRole(dvp.ROLE_GOD(), _godAddress);
        dvp.grantRole(dvp.ROLE_ADMIN(), _adminAddress);
        dvp.grantRole(dvp.ROLE_ADMIN(), _deployerAddress); // TMP
        dvp.grantRole(dvp.ROLE_EPOCH_ROLLER(), _scheduler);
        dvp.grantRole(dvp.ROLE_TRADER(), pm);
        if (!_deployerIsGod) {
            dvp.renounceRole(dvp.ROLE_GOD(), _deployerAddress);
        }

        return address(dvp);
    }

    // TODO: move elsewhere
    function dvpUnregister(address dvpAddr) public {
        vm.startBroadcast(_adminPrivateKey);
        _registry.unregister(dvpAddr);
        vm.stopBroadcast();
    }

    function setVaultMaxDeposit(address vaultAddr, uint256 tvl) public {
        vm.startBroadcast(_adminPrivateKey);
        Vault vault = Vault(vaultAddr);
        tvl = tvl * 10 ** vault.decimals();
        vault.setMaxDeposit(tvl);
        vm.stopBroadcast();
    }

    function useOnchainImpliedVolatility(address igAddress) public {
        vm.startBroadcast(_adminPrivateKey);
        _useOnchainImpliedVolatility(igAddress);
        vm.stopBroadcast();
    }

    function _useOnchainImpliedVolatility(address igAddress) internal {
        IG ig = IG(igAddress);
        TimeLockedFinanceValues memory currentValues = _getTimeLockedFinanceParameters(ig);
        currentValues.useOracleImpliedVolatility = false;

        ig.setParameters(currentValues);
    }

    function _getTimeLockedFinanceParameters(
        IG ig
    ) private view returns (TimeLockedFinanceValues memory currentValues) {
        (, , , , , , TimeLockedFinanceParameters memory igParams, , ) = ig.financeParameters();
        currentValues = TimeLockedFinanceValues({
            sigmaMultiplier: igParams.sigmaMultiplier.get(),
            tradeVolatilityUtilizationRateFactor: igParams.tradeVolatilityUtilizationRateFactor.get(),
            tradeVolatilityTimeDecay: igParams.tradeVolatilityTimeDecay.get(),
            volatilityPriceDiscountFactor: igParams.volatilityPriceDiscountFactor.get(),
            useOracleImpliedVolatility: igParams.useOracleImpliedVolatility.get()
        });
    }

    // // ARBITRUM MAINNET:
    // function runConfiguration() public {
    //     // // USDC / WETH
    //     createIGMarket(0xaf88d065e77c8cC2239327C5EDb3A432268e5831, 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1, 604800, 10800);
    //     setVaultMaxDeposit(_vaultAddr, 1200000);
    //     // USDC / ARB
    //     createIGMarket(0xaf88d065e77c8cC2239327C5EDb3A432268e5831, 0x912CE59144191C1204E64559FE8253a0e49E6548, 604800, 10800);
    //     setVaultMaxDeposit(_vaultAddr, 450000);
    //     setDVPSuccessFee(_dvpAddr, 0.05e18);
    //     // // USDC / GMX
    //     createIGMarket(0xaf88d065e77c8cC2239327C5EDb3A432268e5831, 0xfc5A1A6EB076a2C7aD06eD22C90d7E710E35ad0a, 604800, 10800);
    //     setVaultMaxDeposit(_vaultAddr, 150000);
    //     setDVPSuccessFee(_dvpAddr, 0.05e18);
    //     // // USDC / WBTC
    //     createIGMarket(0xaf88d065e77c8cC2239327C5EDb3A432268e5831, 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f, 604800, 10800);
    //     setVaultMaxDeposit(_vaultAddr, 1200000);
    // }
}
