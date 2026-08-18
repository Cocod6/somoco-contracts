// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PredictionMarket} from "./PredictionMarket.sol";

/// @notice The slice of MarketFactory this contract needs. Kept minimal so the
/// jury is decoupled from everything else the factory does.
interface IMarketFactory {
    function resolver() external view returns (address);
    function proposeResolver(address newResolver) external;
    function acceptResolver() external;
}

/// @title FriendJury
/// @notice Lets a private group of friends settle their own market, instead of
/// Somoco settling it for them — see docs/friend-markets-v1-spec.md.
///
/// This contract is a *resolver*, not a market. `PredictionMarket.resolve()`
/// asks one question — "is the caller `factory.resolver()`?" — and never cares
/// whether that address is a person or a contract. So FriendJury can become the
/// factory's resolver and decide, per market, who is allowed to declare the
/// outcome. No deployed market or factory code changes at all.
///
/// Two kinds of market then coexist under one factory:
/// - **No jury registered** — ordinary Somoco market. `adminResolve` passes the
///   owner's decision straight through, exactly as the EOA resolver did before.
/// - **Jury registered** — a friend market. Somoco cannot declare its outcome
///   at all; only the voters (unanimously) or their named judge can.
///
/// The settlement rule, and why it is this one:
/// 1. Everyone invited votes. **If they all agree, it settles immediately** —
///    the ordinary case, since friends usually agree on what happened.
/// 2. **Any disagreement, or anyone failing to vote in time, escalates to the
///    judge**, who is named up front and must have no money in the market.
/// Voting cannot be weighted by stake (the biggest wallet would simply always
/// win) and disagreement cannot mean "refund" (the losing side would then
/// always disagree, and no one would ever lose). Escalation is what leaves a
/// liar with nothing to gain.
///
/// If the judge also goes silent, nothing is stuck: `voidAfterTimeout()` on the
/// market itself is permissionless 30 days after the resolution date, and
/// refunds everybody. That escape hatch is already deployed and is why every
/// deadline in here is capped below 30 days.
contract FriendJury {
    // ---------------------------------------------------------------- types

    struct Jury {
        /// @dev Non-zero judge doubles as "this market has a jury".
        address judge;
        /// @notice Voting opens here — the market's own resolution date.
        uint64 opensAt;
        /// @notice After this, the judge may step in even without a dispute.
        uint64 judgeFrom;
        uint8 voterCount;
        uint8 votesCast;
        uint8 votesYes;
        uint8 votesNo;
        /// @dev Set before the outward call to the market (checks-effects).
        bool finalized;
    }

    // ------------------------------------------------------------ constants

    /// @notice Upper bound on a friend group. Keeps the vote counters in uint8
    /// and the registration loop cheap; 20 is far past a real group of friends.
    uint256 public constant MAX_VOTERS = 20;

    /// @notice Bounds on how long the group gets before the judge may act
    /// unprompted. The ceiling matters: `PredictionMarket.RESOLUTION_TIMEOUT`
    /// is 30 days from the resolution date, so a window at or past that would
    /// let the market be voided out from under a judge who still had the floor.
    uint64 public constant MIN_VOTE_WINDOW = 1 hours;
    uint64 public constant MAX_VOTE_WINDOW = 21 days;

    // -------------------------------------------------------------- storage

    /// @notice The Somoco factory whose markets this contract resolves.
    IMarketFactory public immutable factory;

    /// @notice Somoco admin. Two-step transfer, same discipline as the factory.
    address public owner;
    address public pendingOwner;

    mapping(address market => Jury) private _juries;
    mapping(address market => address[] voters) private _voters;
    mapping(address market => mapping(address voter => bool)) public isVoter;
    /// @notice 0 = has not voted, otherwise the `Outcome` they voted for.
    mapping(address market => mapping(address voter => uint8)) public voteOf;

    // --------------------------------------------------------------- events

    event JuryRegistered(address indexed market, address indexed judge, uint256 voterCount, uint64 judgeFrom);
    event VoteCast(address indexed market, address indexed voter, uint8 outcome);
    event ResolvedUnanimously(address indexed market, uint8 outcome);
    event ResolvedByJudge(address indexed market, address indexed judge, uint8 outcome);
    event ResolvedByAdmin(address indexed market, uint8 outcome);
    event VoidedByAdmin(address indexed market);
    event OwnershipTransferStarted(address indexed previous, address indexed proposed);
    event OwnershipTransferred(address indexed previous, address indexed current);

    // --------------------------------------------------------------- errors

    error NotOwner();
    error NotPendingOwner();
    error ZeroAddress();
    error ForeignMarket();
    error AlreadyRegistered();
    error NoJury();
    error HasJury();
    error TooFewVoters();
    error TooManyVoters();
    error DuplicateVoter();
    error JudgeCannotVote();
    error JudgeHasStake();
    error BadVoteWindow();
    error MarketAlreadyFinal();
    error VotingNotOpen();
    error VotingClosed();
    error NotAVoter();
    error AlreadyVoted();
    error InvalidOutcome();
    error NotJudge();
    error JudgeNotYet();

    // ---------------------------------------------------------------- setup

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address factory_, address owner_) {
        if (factory_ == address(0) || owner_ == address(0)) revert ZeroAddress();
        factory = IMarketFactory(factory_);
        owner = owner_;
        emit OwnershipTransferred(address(0), owner_);
    }

    // ------------------------------------------------------------ resolver role

    /// @notice Step 2 of the factory's resolver handover: claim the role.
    /// Permissionless on purpose — it only succeeds if the current resolver has
    /// already proposed this exact contract, so there is nothing to gate.
    function acceptResolverRole() external {
        factory.acceptResolver();
    }

    /// @notice Escape hatch. Hands the resolver role back to an EOA (or a newer
    /// jury) if this contract turns out to be wrong. The recipient still has to
    /// call `acceptResolver()` themselves, so a typo here is recoverable.
    /// @dev Deliberately does NOT clear registered juries: if the role moves
    /// away, friend markets simply fall back to whoever holds it next.
    function handBackResolverRole(address newResolver) external onlyOwner {
        factory.proposeResolver(newResolver);
    }

    // ------------------------------------------------------------- registration

    /// @notice Turn an existing market into a friend market.
    /// @dev Owner-only because market creation is owner-only on the factory:
    /// Somoco creates the market and registers its jury in the same flow.
    /// @param market The market to gate. Must belong to this contract's factory.
    /// @param voters_ Everyone invited to bet, and therefore to vote. All of
    /// them must vote the same way for the fast path; any gap escalates.
    /// @param judge_ The tiebreaker. Must not be a voter, and must still hold
    /// no position at the moment they rule (checked then, not now — nobody has
    /// staked yet at registration).
    /// @param voteWindow How long the group has after the resolution date
    /// before the judge may rule unprompted.
    function registerJury(address market, address[] calldata voters_, address judge_, uint64 voteWindow)
        external
        onlyOwner
    {
        if (judge_ == address(0)) revert ZeroAddress();
        if (_juries[market].judge != address(0)) revert AlreadyRegistered();
        if (voters_.length < 2) revert TooFewVoters();
        if (voters_.length > MAX_VOTERS) revert TooManyVoters();
        if (voteWindow < MIN_VOTE_WINDOW || voteWindow > MAX_VOTE_WINDOW) revert BadVoteWindow();

        // Must be one of our own markets — otherwise this contract would be
        // storing juries for markets it can never resolve.
        PredictionMarket m = PredictionMarket(market);
        if (m.factory() != address(factory)) revert ForeignMarket();
        if (m.state() == PredictionMarket.State.Resolved || m.state() == PredictionMarket.State.Voided) {
            revert MarketAlreadyFinal();
        }

        for (uint256 i = 0; i < voters_.length; i++) {
            address v = voters_[i];
            if (v == address(0)) revert ZeroAddress();
            if (v == judge_) revert JudgeCannotVote();
            if (isVoter[market][v]) revert DuplicateVoter();
            isVoter[market][v] = true;
            _voters[market].push(v);
        }

        uint64 opensAt = m.resolutionDate();
        _juries[market] = Jury({
            judge: judge_,
            opensAt: opensAt,
            judgeFrom: opensAt + voteWindow,
            voterCount: uint8(voters_.length),
            votesCast: 0,
            votesYes: 0,
            votesNo: 0,
            finalized: false
        });

        emit JuryRegistered(market, judge_, voters_.length, opensAt + voteWindow);
    }

    // -------------------------------------------------------------- voting

    /// @notice Say what happened. One vote each, and it cannot be changed —
    /// a changeable vote would just be a negotiation with the pot on the table.
    /// @dev Settles the market on the spot once everyone has voted the same way.
    function castVote(address market, uint8 outcome) external {
        Jury storage j = _juries[market];
        if (j.judge == address(0)) revert NoJury();
        if (j.finalized) revert VotingClosed();
        if (!isVoter[market][msg.sender]) revert NotAVoter();
        if (voteOf[market][msg.sender] != 0) revert AlreadyVoted();
        if (block.timestamp < j.opensAt) revert VotingNotOpen();
        if (outcome != uint8(PredictionMarket.Outcome.Yes) && outcome != uint8(PredictionMarket.Outcome.No)) {
            revert InvalidOutcome();
        }

        voteOf[market][msg.sender] = outcome;
        j.votesCast += 1;
        if (outcome == uint8(PredictionMarket.Outcome.Yes)) j.votesYes += 1;
        else j.votesNo += 1;
        emit VoteCast(market, msg.sender, outcome);

        // Everyone in, everyone agreed: settle now, no judge needed.
        if (j.votesCast == j.voterCount && (j.votesYes == 0 || j.votesNo == 0)) {
            j.finalized = true;
            emit ResolvedUnanimously(market, outcome);
            PredictionMarket(market).resolve(PredictionMarket.Outcome(outcome));
        }
    }

    /// @notice The judge's ruling. Allowed as soon as the votes are split (no
    /// point making a settled dispute wait) and otherwise once the window has
    /// passed — which covers the ordinary "one friend never showed up" case.
    function judgeResolve(address market, uint8 outcome) external {
        Jury storage j = _juries[market];
        if (j.judge == address(0)) revert NoJury();
        if (j.finalized) revert VotingClosed();
        if (msg.sender != j.judge) revert NotJudge();
        if (outcome != uint8(PredictionMarket.Outcome.Yes) && outcome != uint8(PredictionMarket.Outcome.No)) {
            revert InvalidOutcome();
        }

        bool disputed = j.votesYes > 0 && j.votesNo > 0;
        if (!disputed && block.timestamp < j.judgeFrom) revert JudgeNotYet();

        // A judge with money on the market is not a judge. Checked here rather
        // than at registration because at registration nobody has staked yet.
        PredictionMarket m = PredictionMarket(market);
        if (m.stakeYes(msg.sender) != 0 || m.stakeNo(msg.sender) != 0) revert JudgeHasStake();

        j.finalized = true;
        emit ResolvedByJudge(market, msg.sender, outcome);
        m.resolve(PredictionMarket.Outcome(outcome));
    }

    // --------------------------------------------------------------- admin

    /// @notice Resolve an ordinary Somoco market. This is the passthrough that
    /// keeps every existing market working once this contract holds the role.
    /// @dev Refuses a friend market by design. Somoco creates those markets and
    /// could otherwise overrule the friends who staked in them, which would
    /// make the whole feature a promise rather than a guarantee.
    function adminResolve(address market, uint8 outcome) external onlyOwner {
        if (_juries[market].judge != address(0)) revert HasJury();
        if (outcome != uint8(PredictionMarket.Outcome.Yes) && outcome != uint8(PredictionMarket.Outcome.No)) {
            revert InvalidOutcome();
        }
        emit ResolvedByAdmin(market, outcome);
        PredictionMarket(market).resolve(PredictionMarket.Outcome(outcome));
    }

    /// @notice Void any market, friend market included. Unlike resolving, this
    /// cannot take anyone's money — it only refunds — so Somoco keeps it as the
    /// remedy for an illegal, unanswerable or abusive market.
    function adminVoid(address market) external onlyOwner {
        Jury storage j = _juries[market];
        if (j.judge != address(0)) j.finalized = true;
        emit VoidedByAdmin(market);
        PredictionMarket(market).void();
    }

    // ------------------------------------------------------ owner handover

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    // ---------------------------------------------------------------- views

    function juryOf(address market) external view returns (Jury memory) {
        return _juries[market];
    }

    function votersOf(address market) external view returns (address[] memory) {
        return _voters[market];
    }

    function hasJury(address market) external view returns (bool) {
        return _juries[market].judge != address(0);
    }

    /// @notice Everything the interface needs to draw the voting panel, in one
    /// call. Returns the jury as a struct rather than a long tuple — ten
    /// separate return values overflow the stack without via-ir, and the rest
    /// of this project compiles without it.
    /// @return jury The stored record (all zeros when there is no jury).
    /// @return registered Whether this market is a friend market at all.
    /// @return disputed Whether the votes cast so far point both ways.
    /// @return judgeCanActNow Whether the judge could rule at this moment.
    function status(address market)
        external
        view
        returns (Jury memory jury, bool registered, bool disputed, bool judgeCanActNow)
    {
        jury = _juries[market];
        registered = jury.judge != address(0);
        disputed = jury.votesYes > 0 && jury.votesNo > 0;
        judgeCanActNow =
            registered && !jury.finalized && (disputed || block.timestamp >= jury.judgeFrom);
    }
}
