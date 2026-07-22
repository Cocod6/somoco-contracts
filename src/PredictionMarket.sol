// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Minimal view of the factory: markets read the current resolver and
/// treasury from it so a role handover applies to every market at once.
interface IMarketFactory {
    function resolver() external view returns (address);
    function treasury() external view returns (address);
}

/// @title PredictionMarket
/// @notice Parimutuel YES/NO pool for one Somoco prediction, denominated in
/// native $TRUST (Intuition mainnet). Deployed as an EIP-1167 clone by
/// `MarketFactory` — see docs/settlement-v1-spec.md for the full spec.
///
/// Key properties:
/// - Staking is one-way: no unstake, no early exit (parimutuel v1 design).
/// - Locking is time-derived, never a transaction.
/// - The 3% fee is charged on the losing pool only — a winner never receives
///   less than their own stake back. The fee splits between the prediction's
///   creator (`creatorFeeBps`, snapshotted at creation) and Somoco's treasury,
///   and is auto-distributed at resolution (best-effort; `sweepFee()` retries).
/// - Resolution with an empty side (no losers, or no winners) voids the market
///   and refunds everyone fee-free.
/// - If the resolver goes silent, anyone can void after a 30-day timeout.
contract PredictionMarket is ReentrancyGuard {
    // ---------------------------------------------------------------- types

    enum Side {
        Yes,
        No
    }

    enum Outcome {
        Unresolved,
        Yes,
        No
    }

    /// @dev `Locked` is virtual — derived from time, never stored (§4).
    enum State {
        Open,
        Locked,
        Resolved,
        Voided
    }

    // ------------------------------------------------------------ constants

    /// @notice Somoco's commission on the losing pool, in basis points (3%).
    uint256 public constant FEE_BPS = 300;
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice After `resolutionDate + RESOLUTION_TIMEOUT`, anyone may void (§7).
    uint256 public constant RESOLUTION_TIMEOUT = 30 days;

    /// @notice After a market is final for this long, remaining dust/unclaimed
    /// funds may be swept to the treasury (§5, Rounding).
    uint256 public constant DUST_GRACE = 180 days;

    /// @notice Early-exit penalty, in bps. A user who unstakes before the
    /// market locks keeps `(1 - UNSTAKE_PENALTY)` of their stake; the forfeited
    /// remainder stays in the pool and is split among the winning side at
    /// resolution (rewards conviction). 4000 = 40%.
    uint256 public constant UNSTAKE_PENALTY_BPS = 4000;

    // -------------------------------------------------------------- storage

    /// @notice The factory that deployed and initialized this clone.
    /// @dev Doubles as the initialization guard: non-zero means initialized.
    address public factory;

    /// @notice Intuition Triple id this market settles. bytes32, never uint (§3).
    bytes32 public termId;

    /// @notice Unix seconds when the outcome becomes knowable.
    uint64 public resolutionDate;

    /// @notice Staking closes at this timestamp (`resolutionDate - lockOffset`).
    uint64 public lockAt;

    /// @notice Timestamp the market became Resolved or Voided (0 while open).
    uint64 public finalizedAt;

    /// @notice Minimum stake per call, snapshotted from the factory at creation.
    uint256 public minStake;

    /// @notice The prediction's creator — earns `creatorFeeBps` of the losing
    /// pool when the market resolves (their reward for making the market).
    address public creator;

    /// @notice Creator's slice of the fee in bps, snapshotted from the factory
    /// at creation. Always <= FEE_BPS; the remainder goes to the treasury.
    uint16 public creatorFeeBps;

    Outcome public outcome;
    bool public voided;
    bool public feeSwept;
    bool public creatorFeeSettled;

    uint256 public poolYes;
    uint256 public poolNo;

    /// @notice Total fee taken from the losing pool, fixed at resolution.
    /// Used by payout math; split into creator + treasury slices below.
    uint256 public feeAmount;

    /// @notice Creator's slice of `feeAmount`, fixed at resolution.
    uint256 public creatorFeeAmount;

    /// @notice Treasury's slice; grows by the creator's slice if the creator's
    /// receiver reverts (a reverting creator forfeits to the treasury).
    uint256 public treasuryFeeAmount;

    /// @notice Total forfeited by early unstakers (both sides). Added to the
    /// winning side's distributable pot at resolution. On a void it has no
    /// rightful winner and is left in the contract for the dust sweep.
    uint256 public forfeitPool;

    mapping(address => uint256) public stakeYes;
    mapping(address => uint256) public stakeNo;
    mapping(address => bool) public claimed;

    // --------------------------------------------------------------- events

    event Staked(address indexed user, Side side, uint256 amount);
    event Unstaked(address indexed user, Side side, uint256 staked, uint256 refunded, uint256 forfeited);
    event Resolved(Outcome outcome, uint256 poolYes, uint256 poolNo, uint256 fee);
    event Voided(uint256 poolYes, uint256 poolNo);
    event Claimed(address indexed user, uint256 amount);
    event CreatorFeePaid(address indexed creator, uint256 amount);
    event CreatorFeeForfeited(address indexed creator, uint256 amount);
    event FeeSwept(address indexed treasury, uint256 amount);
    event DustSwept(address indexed treasury, uint256 amount);

    // --------------------------------------------------------------- errors

    error AlreadyInitialized();
    error NotResolver();
    error StakingClosed();
    error BelowMinStake();
    error NotLocked();
    error InvalidOutcome();
    error AlreadyFinal();
    error TimeoutNotReached();
    error NotClaimable();
    error AlreadyClaimed();
    error NothingToClaim();
    error NothingStaked();
    error NotResolved();
    error NothingToSweep();
    error GraceNotOver();
    error TransferFailed();

    // ---------------------------------------------------------------- setup

    /// @dev Brick the implementation contract: `factory` set non-zero means
    /// `initialize` can never be called on it (§11, clone initialization guard).
    constructor() {
        factory = address(this);
    }

    /// @notice Called exactly once by the factory right after cloning.
    function initialize(
        bytes32 termId_,
        uint64 resolutionDate_,
        uint64 lockAt_,
        uint256 minStake_,
        address creator_,
        uint16 creatorFeeBps_
    ) external {
        if (factory != address(0)) revert AlreadyInitialized();
        factory = msg.sender;
        termId = termId_;
        resolutionDate = resolutionDate_;
        lockAt = lockAt_;
        minStake = minStake_;
        creator = creator_;
        creatorFeeBps = creatorFeeBps_;
    }

    // ---------------------------------------------------------------- views

    /// @notice Current state; `Locked` is derived from time, not stored (§4).
    function state() public view returns (State) {
        if (voided) return State.Voided;
        if (outcome != Outcome.Unresolved) return State.Resolved;
        if (block.timestamp >= lockAt) return State.Locked;
        return State.Open;
    }

    /// @notice What `user` would receive from `claim()` right now.
    /// Returns 0 if the market isn't final, the user already claimed, or lost.
    function claimableOf(address user) external view returns (uint256) {
        if (claimed[user]) return 0;
        return _payoutOf(user);
    }

    // -------------------------------------------------------------- staking

    /// @notice Stake native $TRUST on a side. Staking both sides is allowed;
    /// repeat stakes accumulate. Positions can be exited early via `unstake`
    /// while the market is Open, at the `UNSTAKE_PENALTY_BPS` cost.
    function stake(Side side) external payable {
        if (state() != State.Open) revert StakingClosed();
        if (msg.value < minStake) revert BelowMinStake();

        if (side == Side.Yes) {
            poolYes += msg.value;
            stakeYes[msg.sender] += msg.value;
        } else {
            poolNo += msg.value;
            stakeNo[msg.sender] += msg.value;
        }
        emit Staked(msg.sender, side, msg.value);
    }

    /// @notice Exit a position early, before the market locks. Returns the
    /// whole of one side's stake minus the `UNSTAKE_PENALTY_BPS` penalty; the
    /// forfeited portion stays in the pool and boosts the winning side at
    /// resolution. Full-position exit per side (unstake YES and NO separately).
    function unstake(Side side) external nonReentrant {
        if (state() != State.Open) revert StakingClosed();

        uint256 staked = side == Side.Yes ? stakeYes[msg.sender] : stakeNo[msg.sender];
        if (staked == 0) revert NothingStaked();

        uint256 forfeit = (staked * UNSTAKE_PENALTY_BPS) / BPS_DENOMINATOR;
        uint256 refund = staked - forfeit;

        // Effects: clear the position, shrink the pool by the amount returned,
        // and keep the forfeit as un-owned pool value. The balance invariant
        // `balance == poolYes + poolNo + forfeitPool` is preserved.
        if (side == Side.Yes) {
            stakeYes[msg.sender] = 0;
            poolYes -= staked;
        } else {
            stakeNo[msg.sender] = 0;
            poolNo -= staked;
        }
        forfeitPool += forfeit;

        _pay(msg.sender, refund);
        emit Unstaked(msg.sender, side, staked, refund, forfeit);
    }

    // ----------------------------------------------------------- resolution

    /// @notice Declare the outcome. Resolver only, and only once Locked (§7).
    /// @dev Voids only when the WINNING side has no stakers (no rightful winner)
    /// — that also covers the empty-market case (§8). A one-sided market where
    /// only the winning side has stakers is NOT voided: those winners get their
    /// stake back (plus any forfeit pot) via the normal payout, with zero fee
    /// on an empty losing pool. Fees are auto-distributed here, best-effort:
    /// a failed transfer never blocks resolution and can be retried via `sweepFee()`.
    function resolve(Outcome outcome_) external nonReentrant {
        if (msg.sender != IMarketFactory(factory).resolver()) revert NotResolver();
        if (state() != State.Locked) revert NotLocked();
        if (outcome_ == Outcome.Unresolved) revert InvalidOutcome();

        uint256 winningPool = outcome_ == Outcome.Yes ? poolYes : poolNo;
        if (winningPool == 0) {
            _void();
            return;
        }

        outcome = outcome_;
        finalizedAt = uint64(block.timestamp);
        uint256 losingPool = outcome_ == Outcome.Yes ? poolNo : poolYes;
        feeAmount = (losingPool * FEE_BPS) / BPS_DENOMINATOR;
        creatorFeeAmount = (losingPool * creatorFeeBps) / BPS_DENOMINATOR;
        treasuryFeeAmount = feeAmount - creatorFeeAmount;
        emit Resolved(outcome_, poolYes, poolNo, feeAmount);

        _distributeFees();
    }

    /// @dev Pay the creator and treasury their fee slices. Best-effort by
    /// design: a reverting creator forfeits their slice to the treasury; a
    /// reverting treasury leaves `feeSwept` false so `sweepFee()` can retry.
    function _distributeFees() internal {
        if (creatorFeeAmount > 0 && !creatorFeeSettled) {
            creatorFeeSettled = true;
            (bool ok,) = creator.call{value: creatorFeeAmount}("");
            if (ok) {
                emit CreatorFeePaid(creator, creatorFeeAmount);
            } else {
                treasuryFeeAmount += creatorFeeAmount;
                emit CreatorFeeForfeited(creator, creatorFeeAmount);
            }
        }
        if (treasuryFeeAmount > 0 && !feeSwept) {
            address treasury = IMarketFactory(factory).treasury();
            (bool ok,) = treasury.call{value: treasuryFeeAmount}("");
            if (ok) {
                feeSwept = true;
                emit FeeSwept(treasury, treasuryFeeAmount);
            }
        }
    }

    /// @notice Void the market (outcome impossible/ambiguous). Resolver only.
    /// Reachable from Open or Locked (§8). Refunds are fee-free.
    function void() external {
        if (msg.sender != IMarketFactory(factory).resolver()) revert NotResolver();
        State s = state();
        if (s == State.Resolved || s == State.Voided) revert AlreadyFinal();
        _void();
    }

    /// @notice Permissionless escape hatch: if the resolver never resolves,
    /// anyone can void after the timeout so funds are never stuck (§7).
    function voidAfterTimeout() external {
        if (block.timestamp <= uint256(resolutionDate) + RESOLUTION_TIMEOUT) revert TimeoutNotReached();
        State s = state();
        if (s == State.Resolved || s == State.Voided) revert AlreadyFinal();
        _void();
    }

    function _void() internal {
        voided = true;
        finalizedAt = uint64(block.timestamp);
        emit Voided(poolYes, poolNo);
    }

    // ------------------------------------------------------------- claiming

    /// @notice Withdraw winnings (Resolved) or refund (Voided). Pull-payment,
    /// idempotent: a second call reverts and pays nothing (§11).
    function claim() external nonReentrant {
        State s = state();
        if (s != State.Resolved && s != State.Voided) revert NotClaimable();
        if (claimed[msg.sender]) revert AlreadyClaimed();

        uint256 amount = _payoutOf(msg.sender);
        if (amount == 0) revert NothingToClaim();

        // Effects before interaction.
        claimed[msg.sender] = true;
        _pay(msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    /// @dev Payout math per §5. Voided → exact refund of both sides, no fee
    /// (the forfeit pot has no rightful winner and is left for the dust sweep).
    /// Resolved → own winning stake back + pro-rata share of (the losing pool
    /// net of fee) plus the early-exit forfeit pot, via full-precision mulDiv
    /// to minimise rounding dust.
    function _payoutOf(address user) internal view returns (uint256) {
        if (voided) {
            return stakeYes[user] + stakeNo[user];
        }
        if (outcome == Outcome.Unresolved) return 0;

        uint256 winStake = outcome == Outcome.Yes ? stakeYes[user] : stakeNo[user];
        if (winStake == 0) return 0;

        uint256 winningPool = outcome == Outcome.Yes ? poolYes : poolNo;
        uint256 losingPool = outcome == Outcome.Yes ? poolNo : poolYes;
        uint256 distributed = (losingPool - feeAmount) + forfeitPool;

        return winStake + Math.mulDiv(winStake, distributed, winningPool);
    }

    // ------------------------------------------------------------- sweeping

    /// @notice Retry fee distribution if the automatic attempt at resolution
    /// failed (e.g. the treasury reverted). Callable by anyone, only after a
    /// real resolution (a voided market earns nobody anything, §8).
    function sweepFee() external nonReentrant {
        if (outcome == Outcome.Unresolved) revert NotResolved();
        bool pending = (creatorFeeAmount > 0 && !creatorFeeSettled) || (treasuryFeeAmount > 0 && !feeSwept);
        if (!pending) revert NothingToSweep();
        _distributeFees();
    }

    /// @notice After the market has been final for `DUST_GRACE`, sweep whatever
    /// remains (rounding dust + unclaimed payouts) to the treasury (§5).
    function sweepDust() external nonReentrant {
        if (finalizedAt == 0) revert NotClaimable();
        if (block.timestamp < uint256(finalizedAt) + DUST_GRACE) revert GraceNotOver();

        uint256 balance = address(this).balance;
        // Unswept fee slices are part of the remaining balance; mark them
        // settled so sweepFee can't double-pay afterwards.
        feeSwept = true;
        creatorFeeSettled = true;
        if (balance == 0) revert NothingToSweep();

        address treasury = IMarketFactory(factory).treasury();
        _pay(treasury, balance);
        emit DustSwept(treasury, balance);
    }

    // -------------------------------------------------------------- helpers

    function _pay(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
