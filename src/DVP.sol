// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAddressProvider} from "./interfaces/IAddressProvider.sol";
import {IDVP, IDVPImmutables} from "./interfaces/IDVP.sol";
import {IEpochControls} from "./interfaces/IEpochControls.sol";
import {IFeeManager} from "./interfaces/IFeeManager.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {IVault} from "./interfaces/IVault.sol";
import {Amount, AmountHelper} from "./lib/Amount.sol";
import {AmountsMath} from "./lib/AmountsMath.sol";
import {Epoch} from "./lib/EpochController.sol";
import {Finance} from "./lib/Finance.sol";
import {Notional} from "./lib/Notional.sol";
import {Position} from "./lib/Position.sol";
import {EpochControls} from "./EpochControls.sol";

abstract contract DVP is IDVP, EpochControls, Ownable, Pausable {
    using AmountHelper for Amount;
    using AmountsMath for uint256;
    using Position for Position.Info;
    using Notional for Notional.Info;
    using SafeERC20 for IERC20Metadata;

    /// @inheritdoc IDVPImmutables
    address public immutable override baseToken;
    /// @inheritdoc IDVPImmutables
    address public immutable override sideToken;
    /// @inheritdoc IDVPImmutables
    bool public immutable override optionType; // ToDo: review (it's a DVPType)
    /// @inheritdoc IDVP
    address public immutable override vault;

    IAddressProvider internal immutable _addressProvider;
    uint8 internal immutable _baseTokenDecimals;
    uint8 internal immutable _sideTokenDecimals;

    // TBD: define lot size

    // TBD: extract payoff from Notional.Info
    // TBD: move strike and strategy outside of struct as indexes
    // TBD: merge with _epochPositions as both are indexed by epoch
    /**
        @notice liquidity for options indexed by epoch
        @dev mapping epoch -> Notional.Info
     */
    mapping(uint256 => Notional.Info) internal _liquidity;

    // TBD: use a user-defined type for the position ID, as well as for the epoch
    /**
        @notice Users positions
        @dev mapping epoch -> Position.getID(...) -> Position.Info
        @dev There is an index by epoch in order to further avoid collisions within the hash of the position ID.
     */
    mapping(uint256 => mapping(bytes32 => Position.Info)) internal _epochPositions;

    error NotEnoughLiquidity();
    error PositionNotFound();
    error CantBurnMoreThanMinted();
    error MissingMarketOracle();
    error MissingPriceOracle();
    error MissingFeeManager();
    error SlippedMarketValue();

    /**
        @notice Emitted when option is minted for a given position
        @param sender The address that minted the option
        @param owner The owner of the option
     */
    event Mint(address sender, address indexed owner);

    /**
        @notice Emitted when a position's option is destroyed
        @param owner The owner of the position that is being burnt
     */
    event Burn(address indexed owner);

    constructor(
        address vault_,
        bool optionType_,
        address addressProvider_
    ) EpochControls(IEpochControls(vault_).getEpoch().frequency) Ownable() Pausable() {
        // ToDo: validate parameters
        optionType = optionType_;
        vault = vault_;
        IVault vaultCt = IVault(vault);
        baseToken = vaultCt.baseToken();
        sideToken = vaultCt.sideToken();
        _baseTokenDecimals = IERC20Metadata(baseToken).decimals();
        _sideTokenDecimals = IERC20Metadata(sideToken).decimals();
        _addressProvider = IAddressProvider(addressProvider_);
    }

    /**
        @notice Mint or increase a position.
        @param recipient The wallet of the recipient for the opened position.
        @param strike The strike.
        @param amount The notional.
        @param expectedPremium The expected premium; used to check the slippage.
        @param maxSlippage The maximum slippage percentage.
        @return premium_ The paid premium.
        @dev The client must have approved the needed premium.
     */
    function _mint(
        address recipient,
        uint256 strike,
        Amount memory amount,
        uint256 expectedPremium,
        uint256 maxSlippage
    ) internal returns (uint256 premium_) {
        _mintBurnChecks();
        if (amount.up == 0 && amount.down == 0) {
            revert AmountZero();
        }

        Epoch memory epoch = getEpoch();
        Notional.Info storage liquidity = _liquidity[epoch.current];

        // Check available liquidity:
        Amount memory availableLiquidity = liquidity.available(strike);
        if (availableLiquidity.up < amount.up || availableLiquidity.down < amount.down) {
            revert NotEnoughLiquidity();
        }

        uint256 swapPrice = _deltaHedgePosition(strike, amount, true);

        premium_ = _getMarketValue(strike, amount, true, swapPrice);

        IFeeManager feeManager = IFeeManager(_getFeeManager());
        uint256 fee = feeManager.calculateTradeFee(amount.up + amount.down, premium_, _baseTokenDecimals, false);

        // Revert if actual price exceeds the previewed premium
        // NOTE: cannot use the approved premium as a reference due to the PositionManager...
        _checkSlippage(premium_, fee, expectedPremium, maxSlippage, true);
        // ToDo: revert if the premium is zero due to an underflow
        // ----- it may be avoided by asking for a positive number of lots as notional...

        // Get base premium from sender:
        IERC20Metadata(baseToken).safeTransferFrom(msg.sender, vault, premium_);

        // Get fees from sender:
        IERC20Metadata(baseToken).safeTransferFrom(msg.sender, address(this), fee);
        IERC20Metadata(baseToken).safeApprove(address(feeManager), fee);
        feeManager.receiveFee(fee);

        // Update user premium:
        premium_ += fee;

        // Decrease available liquidity:
        liquidity.increaseUsage(strike, amount);

        // Create or update position:
        Position.Info storage position = _getPosition(epoch.current, recipient, strike);
        position.epoch = epoch.current;
        position.strike = strike;
        position.amountUp += amount.up;
        position.amountDown += amount.down;

        emit Mint(msg.sender, recipient);
    }

    function _checkSlippage(
        uint256 marketValue,
        uint256 fee,
        uint256 expectedMarketValue,
        uint256 maxSlippage,
        bool tradeIsBuy
    ) internal pure {
        uint256 slippage = expectedMarketValue.wmul(maxSlippage);

        if (tradeIsBuy && (marketValue + fee > expectedMarketValue + slippage)) {
            revert SlippedMarketValue();
        }
        if (!tradeIsBuy && (marketValue + fee < expectedMarketValue - slippage)) {
            revert SlippedMarketValue();
        }
    }

    /**
        @notice It attempts to flat the DVP's delta by selling/buying an amount of side tokens in order to hedge the position.
        @notice By hedging the position, we avoid the impermanent loss.
        @param strike The position strike.
        @param amount The position notional.
        @param tradeIsBuy Positive if buyed by a user, negative otherwise.
     */
    function _deltaHedgePosition(
        uint256 strike,
        Amount memory amount,
        bool tradeIsBuy
    ) internal virtual returns (uint256 swapPrice);

    /**
        @notice Burn or decrease a position.
        @param epoch_ The epoch of the position.
        @param recipient The wallet of the recipient for the opened position.
        @param strike The strike
        @param amount The notional.
        @param expectedMarketValue The expected market value when the epoch is the current one.
        @param maxSlippage The maximum slippage percentage.
        @return paidPayoff The paid payoff.
     */
    function _burn(
        uint256 epoch_,
        address recipient,
        uint256 strike,
        Amount memory amount,
        uint256 expectedMarketValue,
        uint256 maxSlippage
    ) internal returns (uint256 paidPayoff) {
        _mintBurnChecks();
        Position.Info storage position = _getPosition(epoch_, msg.sender, strike);
        if (!position.exists()) {
            revert PositionNotFound();
        }

        // // If the position reached maturity, the user must close the entire position
        // // NOTE: we have to avoid this due to the PositionManager that holds positions for multiple tokens.
        // if (position.epoch != epoch.current) {
        //     amount = position.amount;
        // }
        if (amount.up == 0 && amount.down == 0) {
            // NOTE: a zero amount may have some parasite effect, henct we proactively protect against it.
            revert AmountZero();
        }
        if (amount.up > position.amountUp || amount.down > position.amountDown) {
            revert CantBurnMoreThanMinted();
        }

        Notional.Info storage liquidity = _liquidity[epoch_];
        IFeeManager feeManager = IFeeManager(_getFeeManager());

        bool reachedMaturity = epoch_ != getEpoch().current;
        uint256 fee;
        if (!reachedMaturity) {
            uint256 swapPrice = _deltaHedgePosition(strike, amount, false);
            // Compute the payoff to be paid:
            paidPayoff = _getMarketValue(strike, amount, false, swapPrice);

            fee = feeManager.calculateTradeFee(
                amount.up + amount.down,
                paidPayoff,
                _baseTokenDecimals,
                reachedMaturity
            );

            _checkSlippage(paidPayoff, fee, expectedMarketValue, maxSlippage, false);
        } else {
            // Compute the payoff to be paid:
            Amount memory payoff_ = liquidity.shareOfPayoff(strike, amount, _baseTokenDecimals);
            paidPayoff = payoff_.getTotal();

            // Account transfer of setted aside payoff:
            liquidity.decreasePayoff(strike, payoff_);

            // Compute fee:
            fee = feeManager.calculateTradeFee(
                amount.up + amount.down,
                paidPayoff,
                _baseTokenDecimals,
                reachedMaturity
            );
        }

        paidPayoff -= fee;

        // Account change of used liquidity between wallet and protocol:
        position.amountUp -= amount.up;
        position.amountDown -= amount.down;
        // NOTE: must be updated after the previous computations based on used liquidity.
        liquidity.decreaseUsage(strike, amount);

        IVault(vault).transferPayoff(recipient, paidPayoff, reachedMaturity);

        IVault(vault).transferPayoff(address(this), fee, reachedMaturity);
        IERC20Metadata(baseToken).safeApprove(address(feeManager), fee);
        feeManager.receiveFee(fee);

        emit Burn(msg.sender);
    }

    function _mintBurnChecks() private view {
        _checkEpochNotFinished();
        _requireNotPaused();
    }

    /// @inheritdoc EpochControls
    function _beforeRollEpoch() internal virtual override {
        _checkOwner();
        _requireNotPaused();

        // NOTE: avoids breaking computations when there is nothing to compute.
        //       This may break when the underlying vault has no liquidity (e.g. on the very first epoch).
        IVault vaultCt = IVault(vault);
        if (vaultCt.v0() > 0) {
            // Accounts the payoff for each strike and strategy of the positions in circulation that is still to be redeemed:
            _accountResidualPayoffs();
            // Reserve the payoff of those positions:
            uint256 payoffToReserve = _residualPayoff();
            vaultCt.reservePayoff(payoffToReserve);
        }

        IEpochControls(vault).rollEpoch();
        // TBD: check if vault is dead and set a specific internal state ?
    }

    /// @inheritdoc EpochControls
    function _afterRollEpoch() internal virtual override {
        uint256 initialCapital = IVault(vault).v0();
        _allocateLiquidity(initialCapital);
    }

    /**
        @notice Setup initial notional for a new epoch.
        @param initialCapital The initial notional.
        @dev The concrete DVP must allocate the initial notional on the various strikes and strategies.
     */
    function _allocateLiquidity(uint256 initialCapital) internal virtual;

    /**
        @notice computes and stores the residual payoffs of the positions in circulation that is still to be redeemed for the closing epoch.
        @dev The concrete DVP must compute and account the payoff for the various strikes and strategies.
     */
    function _accountResidualPayoffs() internal virtual;

    /**
        @notice Utility function made in order to simplify the work done in _accountResidualPayoffs().
     */
    function _accountResidualPayoff(uint256 strike) internal {
        Notional.Info storage liquidity = _liquidity[getEpoch().current];

        // computes the payoff to be set aside at the end of the epoch for the provided strike.
        (uint256 residualAmountUp, uint256 residualAmountDown) = liquidity.getUsed(strike);
        (uint256 percentageUp, uint256 percentageDown) = _residualPayoffPerc(strike);
        (uint256 payoffUp_, uint256 payoffDown_) = Finance.computeResidualPayoffs(
            residualAmountUp,
            percentageUp,
            residualAmountDown,
            percentageDown,
            _baseTokenDecimals
        );

        liquidity.accountPayoffs(strike, payoffUp_, payoffDown_);
    }

    /**
        @notice Returns the accounted payoff of the positions in circulation that is still to be redeemed.
        @return residualPayoff the overall payoff to be set aside for the closing epoch.
        @dev The concrete DVP must iterate on the various strikes and strategies.
     */
    function _residualPayoff() internal view virtual returns (uint256 residualPayoff);

    /**
        @notice computes the payoff percentage (a scale factor) for the given strike at epoch end.
        @param strike the reference strike.
        @return percentageCall the payoff percentage.
        @return percentagePut the payoff percentage.
        @dev The percentage is expected to be defined in Wad (i.e. 100 % := 1e18)
     */
    function _residualPayoffPerc(
        uint256 strike
    ) internal view virtual returns (uint256 percentageCall, uint256 percentagePut);

    /// @dev computes the premium/payoff with the given amount, swap price and post-trade volatility
    function _getMarketValue(
        uint256 strike,
        Amount memory amount,
        bool tradeIsBuy,
        uint256 swapPrice
    ) internal view virtual returns (uint256);

    /// @inheritdoc IDVP
    function payoff(
        uint256 epoch_,
        uint256 strike,
        uint256 amountUp,
        uint256 amountDown
    ) public view virtual returns (uint256 payoff_, uint256 fee_) {
        Position.Info storage position = _getPosition(epoch_, msg.sender, strike);
        if (!position.exists()) {
            // TBD: return 0
            revert PositionNotFound();
        }

        Amount memory amount_ = Amount({up: amountUp, down: amountDown});
        bool reachedMaturity = position.epoch != getEpoch().current;

        if (!reachedMaturity) {
            // The user wants to know how much is her position worth before reaching maturity
            uint256 swapPrice = IPriceOracle(_getPriceOracle()).getPrice(sideToken, baseToken);
            payoff_ = _getMarketValue(strike, amount_, false, swapPrice);
        } else {
            // The position expired, the user must close the entire position
            // The position is eligible for a share of the <epoch, strike, strategy> payoff set aside at epoch end:
            Amount memory payoffAmount_ = _liquidity[position.epoch].shareOfPayoff(
                position.strike,
                amount_,
                _baseTokenDecimals
            );
            payoff_ = payoffAmount_.getTotal();
        }

        IFeeManager feeManager = IFeeManager(_getFeeManager());
        fee_ = feeManager.calculateTradeFee(amount_.up + amount_.down, payoff_, _baseTokenDecimals, reachedMaturity);

        payoff_ -= fee_;
    }

    /**
        @notice Lookups the requested position.
        @param epoch The epoch of the position.
        @param owner The owner of the position.
        @param strike The strike of the position.
        @return position_ The requested position.
        @dev The client should check if the position exists by calling `exists()` on it.
     */
    function _getPosition(
        uint256 epoch,
        address owner,
        uint256 strike
    ) internal view returns (Position.Info storage position_) {
        // TBD: compute the ID without a library call
        return _epochPositions[epoch][Position.getID(owner, strike)];
    }

    function _getMarketOracle() internal view returns (address marketOracle) {
        marketOracle = _addressProvider.marketOracle();

        if (marketOracle == address(0)) {
            revert MissingMarketOracle();
        }
    }

    function _getPriceOracle() internal view returns (address priceOracle) {
        priceOracle = _addressProvider.priceOracle();

        if (priceOracle == address(0)) {
            revert MissingPriceOracle();
        }
    }

    function _getFeeManager() internal view returns (address feeManager) {
        feeManager = _addressProvider.feeManager();

        if (feeManager == address(0)) {
            revert MissingFeeManager();
        }
    }

    /// @inheritdoc IDVP
    function changePauseState() external override {
        _checkOwner();

        if (paused()) {
            _unpause();
        } else {
            _pause();
        }
    }
}
