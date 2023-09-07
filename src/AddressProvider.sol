// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

// TBD: merge with Registry.sol
contract AddressProvider is Ownable {
    address public exchangeAdapter;
    address public priceOracle;
    address public marketOracle;
    address public registry;
    address public dvpPositionManager;
    address public vaultProxy;

    constructor() Ownable() {}

    function setExchangeAdapter(address exchangeAdapter_) public onlyOwner {
        exchangeAdapter = exchangeAdapter_;
    }

    function setPriceOracle(address priceOracle_) public onlyOwner {
        priceOracle = priceOracle_;
    }

    function setMarketOracle(address marketOracle_) public onlyOwner {
        marketOracle = marketOracle_;
    }

    function setRegistry(address registry_) public onlyOwner {
        registry = registry_;
    }

    function setDvpPositionManager(address posManager_) public onlyOwner {
        dvpPositionManager = posManager_;
    }

    function setVaultProxy(address vaultProxy_) public onlyOwner {
        vaultProxy = vaultProxy_;
    }
}
