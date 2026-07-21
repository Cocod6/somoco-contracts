// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {PredictionMarket} from "./PredictionMarket.sol";

/// @title MarketFactory
/// @notice Deploys and tracks Somoco parimutuel markets as EIP-1167 minimal
/// proxy clones of a single `PredictionMarket` implementation (§3 of
/// docs/settlement-v1-spec.md).
///
/// Roles (all expected to be multisigs in production, §7/§10):
/// - `owner`    — Somoco admin; creates markets, sets treasury/minStake.
///                Two-step transfer via OZ Ownable2Step.
/// - `resolver` — declares outcomes on markets; two-step handover so a typo
///                can't brick every market permanently.
/// - `treasury` — receives the 3% fee; separate from the resolver.
contract MarketFactory is Ownable2Step {
    // -------------------------------------------------------------- storage

    /// @notice The PredictionMarket implementation all clones point at.
    address public immutable implementation;

    /// @notice Address allowed to resolve/void markets. Read live by every
    /// market, so a handover here applies platform-wide at once.
    address public resolver;
    address public pendingResolver;

    /// @notice Receiver of market fees and swept dust.
    address public treasury;

    /// @notice Minimum stake snapshotted into each market at creation (§10 #3).
    uint256 public minStake;

    /// @notice One market per Intuition Triple id (§3).
    mapping(bytes32 => address) public marketForTerm;
    address[] private _markets;

    // --------------------------------------------------------------- events

    event MarketCreated(bytes32 indexed termId, address indexed market, uint64 resolutionDate, uint64 lockOffset);
    event ResolverProposed(address indexed current, address indexed proposed);
    event ResolverChanged(address indexed previous, address indexed current);
    event TreasuryChanged(address indexed previous, address indexed current);
    event MinStakeChanged(uint256 previous, uint256 current);

    // --------------------------------------------------------------- errors

    error ZeroAddress();
    error InvalidTermId();
    error DuplicateMarket();
    error ResolutionInPast();
    error InvalidLockOffset();
    error NotResolver();
    error NotPendingResolver();

    // ---------------------------------------------------------------- setup

    constructor(address owner_, address resolver_, address treasury_, uint256 minStake_) Ownable(owner_) {
        if (resolver_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        resolver = resolver_;
        treasury = treasury_;
        minStake = minStake_;
        // The implementation's constructor marks itself initialized, so it can
        // never be hijacked directly (§11).
        implementation = address(new PredictionMarket());
    }

    // ------------------------------------------------------------- creation

    /// @notice Deploy the market for an Intuition Triple. Admin-only in v1
    /// (§10 #1): permissionless creation would let anyone open markets on
    /// claims Somoco doesn't want to be seen settling.
    /// @param termId Intuition Triple id (bytes32 — never cast through uint).
    /// @param resolutionDate Unix seconds when the outcome is knowable.
    /// @param lockOffset Seconds before `resolutionDate` that staking closes.
    function createMarket(bytes32 termId, uint64 resolutionDate, uint64 lockOffset)
        external
        onlyOwner
        returns (address market)
    {
        if (termId == bytes32(0)) revert InvalidTermId();
        if (marketForTerm[termId] != address(0)) revert DuplicateMarket();
        if (resolutionDate <= block.timestamp) revert ResolutionInPast();
        if (lockOffset >= resolutionDate) revert InvalidLockOffset();

        uint64 lockAt = resolutionDate - lockOffset;
        if (lockAt <= block.timestamp) revert InvalidLockOffset();

        market = Clones.clone(implementation);
        PredictionMarket(market).initialize(termId, resolutionDate, lockAt, minStake);

        marketForTerm[termId] = market;
        _markets.push(market);
        emit MarketCreated(termId, market, resolutionDate, lockOffset);
    }

    // ---------------------------------------------------------------- views

    function allMarkets(uint256 index) external view returns (address) {
        return _markets[index];
    }

    function marketCount() external view returns (uint256) {
        return _markets.length;
    }

    // ----------------------------------------------------- resolver handover

    /// @notice Step 1 of resolver handover: current resolver proposes (§7).
    function proposeResolver(address newResolver) external {
        if (msg.sender != resolver) revert NotResolver();
        if (newResolver == address(0)) revert ZeroAddress();
        pendingResolver = newResolver;
        emit ResolverProposed(resolver, newResolver);
    }

    /// @notice Step 2: the proposed resolver accepts, proving it controls the
    /// key — a typo in step 1 can simply be re-proposed.
    function acceptResolver() external {
        if (msg.sender != pendingResolver) revert NotPendingResolver();
        emit ResolverChanged(resolver, msg.sender);
        resolver = msg.sender;
        pendingResolver = address(0);
    }

    // ---------------------------------------------------------------- admin

    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        emit TreasuryChanged(treasury, newTreasury);
        treasury = newTreasury;
    }

    /// @notice Applies to markets created after this call only — existing
    /// markets keep the snapshot they were created with.
    function setMinStake(uint256 newMinStake) external onlyOwner {
        emit MinStakeChanged(minStake, newMinStake);
        minStake = newMinStake;
    }
}
