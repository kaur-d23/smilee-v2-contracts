// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import {Vault} from "../../src/Vault.sol";
import {TestnetToken} from "../../src/testnet/TestnetToken.sol";
import {EnhancedScript} from "../utils/EnhancedScript.sol";

/*
    Reference: https://book.getfoundry.sh/tutorials/solidity-scripting
    ToDo: see https://book.getfoundry.sh/tutorials/best-practices#scripts

    Usage:
        source .env

        # To deploy [and verify] the contracts
        # - On a local network:
        #   NOTE: Make sue that the local node (anvil) is running...
        forge script script/testnet/05_Vault.s.sol:VaultOps --fork-url $RPC_LOCALNET --broadcast -vvvv --sig 'fillVault(address,uint256)' <VAULT_ADDRESS> <AMOUNT>
        # - On a real network:
        #   ToDo: see https://book.getfoundry.sh/reference/forge/forge-script#wallet-options---raw
        forge script script/testnet/05_Vault.s.sol:VaultOps --rpc-url $RPC_MAINNET --broadcast [--verify] -vvvv --sig 'fillVault(address,uint256)' <VAULT_ADDRESS> <AMOUNT>
 */
contract VaultOps is EnhancedScript {
    uint256 internal _deployerPrivateKey;
    address internal _deployerAddress;

    constructor() {
        // Load the private key that will be used for signing the transactions:
        _deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        _deployerAddress = vm.envAddress("DEPLOYER_ADDRESS");
    }

    function run() external {
        string memory txLogs = _getLatestTransactionLogs("03_Factory.s.sol");
        address vaultAddr = _readAddress(txLogs, "Vault");

        fillVault(vaultAddr, 10 ** 18);
    }

    function fillVault(address vaultAddr, uint256 amount) public {
        Vault vault = Vault(vaultAddr);

        vm.startBroadcast(_deployerPrivateKey);

        // Mint tokens:
        TestnetToken baseToken = TestnetToken(vault.baseToken());
        baseToken.mint(_deployerAddress, amount);

        // Deposit:
        baseToken.approve(vaultAddr, amount);
        vault.deposit(amount, _deployerAddress);

        vm.stopBroadcast();
    }
}
