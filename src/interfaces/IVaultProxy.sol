// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

/**
    @title Single entry point for earn positions creation
    @notice Allows to access vaults from a a single contract. Does not manage created positions.
 */
interface IVaultProxy {
    struct DepositParams {
        // Address of the selected vault for deposit
        address vault;
        // Recipient of the deposit receipt (owner of the shares)
        address recipient;
        // Deposited amount (in vault's base tokens)
        uint256 amount;
    }

    /**
        @notice Emitted every time a deposit is completed
        @param vault The address of the selected vault
        @param owner The account who made the deposit
        @param amount The amount of token that has been deposited
     */
    event Deposit(address indexed vault, address indexed owner, uint256 amount);

    /**
        @notice Proxy function to reach `Vault.deposit()`
        @param params The deposit information
     */
    function deposit(DepositParams calldata params) external;
}
