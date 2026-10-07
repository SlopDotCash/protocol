// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ILiquidator} from "../interfaces/ILiquidator.sol";
import {IVenture} from "../interfaces/IVenture.sol";
import {IUmiaHub} from "../interfaces/IUmiaHub.sol";
import {GovernanceTypes} from "../libraries/GovernanceTypes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title SimpleLiquidator
/// @notice A simple pro-rata liquidation strategy for fungible assets.
/// @dev Supports NATIVE and ERC20 assets only. Users burn their entire venture token balance through
///      the venture to claim their pro-rata share, and may claim again for tokens received later.
///      Payouts are `snapshotBalance * burned / totalSupplySnapshot` against a fixed snapshot, and
///      supply cannot grow once liquidation is active, so repeat claims can never draw more than
///      the backing; `totalBurned` enforces that bound explicitly.
contract SimpleLiquidator is ILiquidator, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error TransferFailed();
    /// @notice Thrown when the liquidator is deployed without a hub.
    error InvalidHub();

    // ─────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────

    /// @notice The canonical hub this liquidator trusts to resolve a venture's governance executor.
    address public immutable HUB;

    /// @notice The Venture treasury being liquidated
    address public venture;

    /// @notice The venture token contract address
    address public ventureToken;

    /// @notice Total supply snapshot at liquidation start
    uint256 public totalSupplySnapshot;

    /// @notice Whether liquidation has been initialized
    bool public initialized;

    /// @notice Array of assets being liquidated
    LiquidationAssetSnapshot[] internal _liquidationAssets;

    /// @notice Whether an account has claimed at least once. Informational: claims are repeatable.
    mapping(address => bool) public hasClaimed;

    /// @notice Venture tokens burned through claims so far. Never exceeds `totalSupplySnapshot`.
    uint256 public totalBurned;

    /// @notice Internal struct for asset snapshots
    struct LiquidationAssetSnapshot {
        GovernanceTypes.AssetType assetType;
        address token;
        uint256 tokenId;
        uint256 balance;
    }

    // ─────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────

    /// @notice Binds the liquidator to a hub; call initialize() after deployment.
    constructor(address _hub) {
        if (_hub == address(0)) revert InvalidHub();
        HUB = _hub;
    }

    // ─────────────────────────────────────────────────────────
    // ILiquidator Implementation
    // ─────────────────────────────────────────────────────────

    /// @inheritdoc ILiquidator
    function initialize(address _venture, GovernanceTypes.LiquidationAsset[] calldata _assets, uint256 _totalSupply)
        external
        override
        nonReentrant
    {
        if (initialized) revert AlreadyInitialized();
        if (_venture == address(0)) revert InvalidAssetType();
        if (_totalSupply == 0) revert InvalidAssetType();
        if (msg.sender != IUmiaHub(HUB).governanceExecutor(_venture)) {
            revert CallerNotAuthorized();
        }
        if (IVenture(_venture).authorizedLiquidator() != address(this)) revert CallerNotAuthorized();

        venture = _venture;
        ventureToken = IVenture(_venture).token();
        totalSupplySnapshot = _totalSupply;
        initialized = true;

        // Snapshot asset balances
        uint256 assetCount = _assets.length;
        for (uint256 i = 0; i < assetCount; i++) {
            GovernanceTypes.LiquidationAsset calldata asset = _assets[i];

            // SimpleLiquidator only supports NATIVE and ERC20
            if (
                asset.assetType != GovernanceTypes.AssetType.NATIVE
                    && asset.assetType != GovernanceTypes.AssetType.ERC20
            ) {
                revert InvalidAssetType();
            }

            // The venture token is the claim-burn token, not a distributable asset. If it is listed,
            // skip it: paying it back out pro-rata would let a claimant forward the payout to fresh
            // addresses and burn it again, drawing more than their share. Skipping keeps a governance plan that mistakenly lists it fully executable.
            if (asset.assetType == GovernanceTypes.AssetType.ERC20 && asset.token == ventureToken) {
                continue;
            }

            // Move backing out of the treasury before the snapshot: standing ERC20
            // approvals granted by the venture must not be able to spend claims.
            uint256 balance = _getAssetBalance(asset, _venture);
            if (balance != 0) {
                IVenture(_venture).withdraw(asset.token, address(this), balance);
            }
            // Account for the amount actually received, including transfer fees.
            balance = _getAssetBalance(asset, address(this));
            _liquidationAssets.push(
                LiquidationAssetSnapshot({
                    assetType: asset.assetType, token: asset.token, tokenId: asset.tokenId, balance: balance
                })
            );
        }

        emit Initialized(_venture, _totalSupply, _liquidationAssets.length);
    }

    /// @inheritdoc ILiquidator
    function claim() external override nonReentrant {
        if (!initialized) revert NotInitialized();

        // Get user's venture token balance - must burn ALL of it
        uint256 userBalance = IERC20(ventureToken).balanceOf(msg.sender);
        if (userBalance == 0) revert NothingToClaim();

        // Effects before external calls (CEI). A per-address one-shot flag would strand any tokens
        // that reach the address after its first claim (e.g. vesting releases, LP exits), so claims
        // are repeatable and solvency rests on the burned total staying within the snapshot.
        uint256 burned = totalBurned + userBalance;
        if (burned > totalSupplySnapshot) revert NothingToClaim();
        totalBurned = burned;
        hasClaimed[msg.sender] = true;

        // Burn the tokens via Venture directly from the claimant. This avoids any
        // dependence on ERC20 transfers being available while the token is paused.
        IVenture(venture).burnFrom(msg.sender, userBalance);

        // Calculate and transfer pro-rata share of each asset
        uint256 assetCount = _liquidationAssets.length;
        for (uint256 i = 0; i < assetCount; i++) {
            LiquidationAssetSnapshot memory asset = _liquidationAssets[i];

            // Calculate pro-rata: asset.balance * userBalance / totalSupplySnapshot
            uint256 payout = FullMath.mulDiv(asset.balance, userBalance, totalSupplySnapshot);
            if (payout == 0) continue;

            if (asset.assetType == GovernanceTypes.AssetType.NATIVE) {
                (bool success,) = payable(msg.sender).call{value: payout}("");
                if (!success) revert TransferFailed();
            } else {
                IERC20(asset.token).safeTransfer(msg.sender, payout);
            }
        }

        emit Claimed(msg.sender, userBalance);
    }

    /// @inheritdoc ILiquidator
    function claimableAmount(address _account) external view override returns (uint256[] memory amounts) {
        if (!initialized) revert NotInitialized();

        uint256 userBalance = IERC20(ventureToken).balanceOf(_account);
        uint256 assetCount = _liquidationAssets.length;
        amounts = new uint256[](assetCount);

        if (userBalance == 0) return amounts;

        for (uint256 i = 0; i < assetCount; i++) {
            LiquidationAssetSnapshot memory asset = _liquidationAssets[i];
            amounts[i] = FullMath.mulDiv(asset.balance, userBalance, totalSupplySnapshot);
        }
    }

    /// @inheritdoc ILiquidator
    function liquidationAssets(uint256 _index)
        external
        view
        override
        returns (GovernanceTypes.AssetType assetType, address token, uint256 tokenId, uint256 balance)
    {
        if (_index >= _liquidationAssets.length) revert InvalidAssetType();
        LiquidationAssetSnapshot storage asset = _liquidationAssets[_index];
        return (asset.assetType, asset.token, asset.tokenId, asset.balance);
    }

    /// @inheritdoc ILiquidator
    function liquidationAssetCount() external view override returns (uint256) {
        return _liquidationAssets.length;
    }

    // ─────────────────────────────────────────────────────────
    // Internal Helpers
    // ─────────────────────────────────────────────────────────

    receive() external payable {}

    function _getAssetBalance(GovernanceTypes.LiquidationAsset calldata asset, address account)
        internal
        view
        returns (uint256)
    {
        if (asset.assetType == GovernanceTypes.AssetType.NATIVE) {
            return account.balance;
        }
        if (asset.assetType == GovernanceTypes.AssetType.ERC20) {
            return IERC20(asset.token).balanceOf(account);
        }
        // Should never reach here due to validation in initialize()
        revert InvalidAssetType();
    }
}
