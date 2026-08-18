// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {MarketFactory} from "../src/MarketFactory.sol";
import {PredictionMarket} from "../src/PredictionMarket.sol";
import {FriendJury} from "../src/FriendJury.sol";

contract FriendJuryTest is Test {
    MarketFactory factory;
    FriendJury jury;
    PredictionMarket market; // has a jury
    PredictionMarket plain; // ordinary Somoco market, no jury

    address owner = makeAddr("owner");
    address deployerResolver = makeAddr("deployerResolver"); // the EOA resolver at deploy
    address treasury = makeAddr("treasury");

    address ada = makeAddr("ada");
    address bola = makeAddr("bola");
    address chidi = makeAddr("chidi");
    address dami = makeAddr("dami");
    address judge = makeAddr("judge");
    address rando = makeAddr("rando");

    bytes32 constant TERM_ID = bytes32(uint256(0xf00d));
    bytes32 constant TERM_ID_2 = bytes32(uint256(0xcafe));
    uint256 constant MIN_STAKE = 0.01 ether;
    uint64 constant LOCK_OFFSET = 24 hours;
    uint64 constant VOTE_WINDOW = 3 days;

    uint8 constant YES = uint8(PredictionMarket.Outcome.Yes);
    uint8 constant NO = uint8(PredictionMarket.Outcome.No);

    uint64 resolutionDate;

    function setUp() public {
        vm.warp(1_800_000_000);
        factory = new MarketFactory(owner, deployerResolver, treasury, MIN_STAKE);
        jury = new FriendJury(address(factory), owner);

        // The real handover: the EOA resolver proposes, the contract accepts.
        vm.prank(deployerResolver);
        factory.proposeResolver(address(jury));
        jury.acceptResolverRole();

        resolutionDate = uint64(block.timestamp + 7 days);

        vm.startPrank(owner);
        market = PredictionMarket(factory.createMarket(TERM_ID, resolutionDate, LOCK_OFFSET, ada));
        plain = PredictionMarket(factory.createMarket(TERM_ID_2, resolutionDate, LOCK_OFFSET, ada));
        vm.stopPrank();

        vm.deal(ada, 100 ether);
        vm.deal(bola, 100 ether);
        vm.deal(chidi, 100 ether);
        vm.deal(dami, 100 ether);
        vm.deal(judge, 100 ether);
        vm.deal(rando, 100 ether);
    }

    // ------------------------------------------------------------- helpers

    function _threeVoters() internal view returns (address[] memory v) {
        v = new address[](3);
        v[0] = ada;
        v[1] = bola;
        v[2] = chidi;
    }

    function _register() internal {
        vm.prank(owner);
        jury.registerJury(address(market), _threeVoters(), judge, VOTE_WINDOW);
    }

    function _stake(address who, PredictionMarket.Side side, uint256 amount) internal {
        vm.prank(who);
        market.stake{value: amount}(side);
    }

    /// @dev Everyone bets, then time moves to the resolution date (when voting
    /// opens). The market is Locked by then, which `resolve()` requires.
    function _betAndOpenVoting() internal {
        _stake(ada, PredictionMarket.Side.Yes, 1 ether);
        _stake(bola, PredictionMarket.Side.Yes, 1 ether);
        _stake(chidi, PredictionMarket.Side.No, 2 ether);
        vm.warp(resolutionDate);
    }

    // -------------------------------------------------- the resolver handover

    function test_JuryHoldsResolverRole() public view {
        assertEq(factory.resolver(), address(jury));
    }

    function test_HandBackResolverRole() public {
        address newResolver = makeAddr("newResolver");
        vm.prank(owner);
        jury.handBackResolverRole(newResolver);
        assertEq(factory.pendingResolver(), newResolver);

        vm.prank(newResolver);
        factory.acceptResolver();
        assertEq(factory.resolver(), newResolver);
    }

    function test_RevertWhen_NonOwnerHandsBackRole() public {
        vm.prank(rando);
        vm.expectRevert(FriendJury.NotOwner.selector);
        jury.handBackResolverRole(rando);
    }

    // ------------------------------------------------------------ registration

    function test_RegisterJuryStoresConfig() public {
        _register();
        (FriendJury.Jury memory j, bool registered, bool disputed, bool judgeCanActNow) =
            jury.status(address(market));

        assertTrue(registered);
        assertFalse(disputed);
        assertFalse(judgeCanActNow);
        assertEq(j.judge, judge);
        assertEq(j.opensAt, resolutionDate);
        assertEq(j.judgeFrom, resolutionDate + VOTE_WINDOW);
        assertEq(j.voterCount, 3);
        assertEq(j.votesCast, 0);
        assertFalse(j.finalized);

        address[] memory voters = jury.votersOf(address(market));
        assertEq(voters.length, 3);
        assertEq(voters[0], ada);
        assertTrue(jury.isVoter(address(market), ada));
        assertFalse(jury.isVoter(address(market), rando));
        assertTrue(jury.hasJury(address(market)));
        assertFalse(jury.hasJury(address(plain)));
    }

    function test_RevertWhen_NonOwnerRegisters() public {
        vm.prank(rando);
        vm.expectRevert(FriendJury.NotOwner.selector);
        jury.registerJury(address(market), _threeVoters(), judge, VOTE_WINDOW);
    }

    function test_RevertWhen_RegisteringTwice() public {
        _register();
        vm.prank(owner);
        vm.expectRevert(FriendJury.AlreadyRegistered.selector);
        jury.registerJury(address(market), _threeVoters(), judge, VOTE_WINDOW);
    }

    function test_RevertWhen_JudgeIsAlsoAVoter() public {
        address[] memory v = new address[](2);
        v[0] = ada;
        v[1] = judge;
        vm.prank(owner);
        vm.expectRevert(FriendJury.JudgeCannotVote.selector);
        jury.registerJury(address(market), v, judge, VOTE_WINDOW);
    }

    function test_RevertWhen_DuplicateVoter() public {
        address[] memory v = new address[](3);
        v[0] = ada;
        v[1] = bola;
        v[2] = ada;
        vm.prank(owner);
        vm.expectRevert(FriendJury.DuplicateVoter.selector);
        jury.registerJury(address(market), v, judge, VOTE_WINDOW);
    }

    function test_RevertWhen_FewerThanTwoVoters() public {
        address[] memory v = new address[](1);
        v[0] = ada;
        vm.prank(owner);
        vm.expectRevert(FriendJury.TooFewVoters.selector);
        jury.registerJury(address(market), v, judge, VOTE_WINDOW);
    }

    function test_RevertWhen_TooManyVoters() public {
        address[] memory v = new address[](21);
        for (uint256 i = 0; i < 21; i++) {
            v[i] = address(uint160(0x9000 + i));
        }
        vm.prank(owner);
        vm.expectRevert(FriendJury.TooManyVoters.selector);
        jury.registerJury(address(market), v, judge, VOTE_WINDOW);
    }

    function test_RevertWhen_VoteWindowOutOfBounds() public {
        vm.prank(owner);
        vm.expectRevert(FriendJury.BadVoteWindow.selector);
        jury.registerJury(address(market), _threeVoters(), judge, 1 minutes);

        vm.prank(owner);
        vm.expectRevert(FriendJury.BadVoteWindow.selector);
        jury.registerJury(address(market), _threeVoters(), judge, 22 days);
    }

    /// @dev The window ceiling exists so the judge always has room before the
    /// market's own 30-day permissionless void can pull the rug.
    function test_MaxVoteWindowLeavesRoomBeforeTimeout() public {
        // Read the constant BEFORE pranking: a view call inside the arguments
        // would consume the prank and the registration would revert NotOwner.
        uint64 maxWindow = jury.MAX_VOTE_WINDOW();
        vm.prank(owner);
        jury.registerJury(address(market), _threeVoters(), judge, maxWindow);
        (FriendJury.Jury memory j,,,) = jury.status(address(market));
        assertLt(uint256(j.judgeFrom), uint256(resolutionDate) + market.RESOLUTION_TIMEOUT());
    }

    function test_RevertWhen_MarketBelongsToAnotherFactory() public {
        MarketFactory other = new MarketFactory(owner, deployerResolver, treasury, MIN_STAKE);
        vm.prank(owner);
        address foreign = other.createMarket(TERM_ID, resolutionDate, LOCK_OFFSET, ada);

        vm.prank(owner);
        vm.expectRevert(FriendJury.ForeignMarket.selector);
        jury.registerJury(foreign, _threeVoters(), judge, VOTE_WINDOW);
    }

    // ------------------------------------------------------ the unanimous path

    function test_UnanimousVoteResolvesImmediately() public {
        _register();
        _betAndOpenVoting();

        vm.prank(ada);
        jury.castVote(address(market), YES);
        vm.prank(bola);
        jury.castVote(address(market), YES);
        // Still open — one voter outstanding.
        assertEq(uint8(market.state()), uint8(PredictionMarket.State.Locked));

        vm.prank(chidi);
        jury.castVote(address(market), YES);

        assertEq(uint8(market.state()), uint8(PredictionMarket.State.Resolved));
        assertEq(uint8(market.outcome()), YES);

        (FriendJury.Jury memory j,,,) = jury.status(address(market));
        assertTrue(j.finalized);
        assertEq(j.votesCast, 3);
        assertEq(j.votesYes, 3);
    }

    /// @dev Chidi staked NO and the group agreed NO: the money follows the vote.
    function test_UnanimousNoPaysTheNoSide() public {
        _register();
        _betAndOpenVoting();

        vm.prank(ada);
        jury.castVote(address(market), NO);
        vm.prank(bola);
        jury.castVote(address(market), NO);
        vm.prank(chidi);
        jury.castVote(address(market), NO);

        assertEq(uint8(market.outcome()), NO);

        uint256 before = chidi.balance;
        vm.prank(chidi);
        market.claim();
        // 2 staked back + 2 of losing pool less the 3% fee.
        assertEq(chidi.balance - before, 2 ether + 2 ether - (2 ether * 300) / 10_000);
    }

    function test_RevertWhen_VotingBeforeResolutionDate() public {
        _register();
        _stake(ada, PredictionMarket.Side.Yes, 1 ether);
        vm.warp(resolutionDate - 1);
        vm.prank(ada);
        vm.expectRevert(FriendJury.VotingNotOpen.selector);
        jury.castVote(address(market), YES);
    }

    function test_RevertWhen_NonVoterVotes() public {
        _register();
        _betAndOpenVoting();
        vm.prank(rando);
        vm.expectRevert(FriendJury.NotAVoter.selector);
        jury.castVote(address(market), YES);
    }

    function test_RevertWhen_VotingTwice() public {
        _register();
        _betAndOpenVoting();
        vm.prank(ada);
        jury.castVote(address(market), YES);
        vm.prank(ada);
        vm.expectRevert(FriendJury.AlreadyVoted.selector);
        jury.castVote(address(market), NO);
    }

    function test_RevertWhen_VotingUnresolvedOutcome() public {
        _register();
        _betAndOpenVoting();
        vm.prank(ada);
        vm.expectRevert(FriendJury.InvalidOutcome.selector);
        jury.castVote(address(market), uint8(PredictionMarket.Outcome.Unresolved));
    }

    function test_RevertWhen_VotingOnMarketWithoutJury() public {
        vm.warp(resolutionDate);
        vm.prank(ada);
        vm.expectRevert(FriendJury.NoJury.selector);
        jury.castVote(address(plain), YES);
    }

    // --------------------------------------------------------- the judge path

    /// @dev The scenario the whole design exists for: three friends bet, the
    /// two on the losing side vote for themselves. Majority would rob Chidi.
    function test_SplitVoteDoesNotResolveAndLetsJudgeRuleImmediately() public {
        _register();
        _betAndOpenVoting();

        vm.prank(ada);
        jury.castVote(address(market), YES);
        vm.prank(bola);
        jury.castVote(address(market), YES);
        vm.prank(chidi);
        jury.castVote(address(market), NO);

        // Two-to-one for YES, and it changes nothing.
        assertEq(uint8(market.state()), uint8(PredictionMarket.State.Locked));
        (, , bool disputed, bool judgeCanActNow) = jury.status(address(market));
        assertTrue(disputed);
        assertTrue(judgeCanActNow); // no waiting once it is a real dispute

        vm.prank(judge);
        jury.judgeResolve(address(market), NO);
        assertEq(uint8(market.outcome()), NO);
    }

    function test_JudgeCanRuleAfterWindowWhenSomeoneNeverVotes() public {
        _register();
        _betAndOpenVoting();

        vm.prank(ada);
        jury.castVote(address(market), YES);
        // bola and chidi never show up.

        vm.prank(judge);
        vm.expectRevert(FriendJury.JudgeNotYet.selector);
        jury.judgeResolve(address(market), YES);

        vm.warp(resolutionDate + VOTE_WINDOW);
        vm.prank(judge);
        jury.judgeResolve(address(market), YES);
        assertEq(uint8(market.outcome()), YES);
    }

    function test_RevertWhen_JudgeHasStake() public {
        _register();
        _betAndOpenVoting();
        // The judge quietly took a position.
        vm.warp(resolutionDate - 2 days);
        vm.prank(judge);
        market.stake{value: 1 ether}(PredictionMarket.Side.Yes);
        vm.warp(resolutionDate + VOTE_WINDOW);

        vm.prank(judge);
        vm.expectRevert(FriendJury.JudgeHasStake.selector);
        jury.judgeResolve(address(market), YES);
    }

    function test_RevertWhen_NonJudgeRules() public {
        _register();
        _betAndOpenVoting();
        vm.warp(resolutionDate + VOTE_WINDOW);
        vm.prank(rando);
        vm.expectRevert(FriendJury.NotJudge.selector);
        jury.judgeResolve(address(market), YES);
    }

    function test_RevertWhen_JudgeRulesAfterUnanimousSettlement() public {
        _register();
        _betAndOpenVoting();
        vm.prank(ada);
        jury.castVote(address(market), YES);
        vm.prank(bola);
        jury.castVote(address(market), YES);
        vm.prank(chidi);
        jury.castVote(address(market), YES);

        vm.warp(resolutionDate + VOTE_WINDOW);
        vm.prank(judge);
        vm.expectRevert(FriendJury.VotingClosed.selector);
        jury.judgeResolve(address(market), NO);
    }

    // --------------------------------------------------------- somoco's limits

    /// @dev The promise that makes the feature real: Somoco cannot declare the
    /// outcome of a market its users' friends are settling.
    function test_RevertWhen_AdminResolvesAFriendMarket() public {
        _register();
        _betAndOpenVoting();
        vm.prank(owner);
        vm.expectRevert(FriendJury.HasJury.selector);
        jury.adminResolve(address(market), YES);
    }

    function test_AdminResolvesAnOrdinaryMarket() public {
        vm.prank(ada);
        plain.stake{value: 1 ether}(PredictionMarket.Side.Yes);
        vm.prank(bola);
        plain.stake{value: 1 ether}(PredictionMarket.Side.No);
        vm.warp(resolutionDate);

        vm.prank(owner);
        jury.adminResolve(address(plain), YES);
        assertEq(uint8(plain.outcome()), YES);
    }

    function test_RevertWhen_NonOwnerAdminResolves() public {
        vm.warp(resolutionDate);
        vm.prank(rando);
        vm.expectRevert(FriendJury.NotOwner.selector);
        jury.adminResolve(address(plain), YES);
    }

    /// @dev Voiding only ever refunds, so Somoco keeps it even on a friend
    /// market — it is the remedy for an abusive or unanswerable question.
    function test_AdminCanVoidAFriendMarket() public {
        _register();
        _betAndOpenVoting();

        vm.prank(owner);
        jury.adminVoid(address(market));
        assertEq(uint8(market.state()), uint8(PredictionMarket.State.Voided));

        // Everyone gets exactly their stake back.
        uint256 before = ada.balance;
        vm.prank(ada);
        market.claim();
        assertEq(ada.balance - before, 1 ether);

        // And the jury is closed, so a late vote cannot re-settle it.
        vm.prank(bola);
        vm.expectRevert(FriendJury.VotingClosed.selector);
        jury.castVote(address(market), YES);
    }

    /// @dev The backstop behind the backstop: if voters AND judge all vanish,
    /// the market's own permissionless timeout still frees the money.
    function test_PermissionlessTimeoutStillWorksIfEveryoneVanishes() public {
        _register();
        _betAndOpenVoting();

        vm.warp(resolutionDate + market.RESOLUTION_TIMEOUT() + 1);
        vm.prank(rando);
        market.voidAfterTimeout();
        assertEq(uint8(market.state()), uint8(PredictionMarket.State.Voided));

        uint256 before = chidi.balance;
        vm.prank(chidi);
        market.claim();
        assertEq(chidi.balance - before, 2 ether);
    }

    // -------------------------------------------------------- owner handover

    function test_TwoStepOwnershipHandover() public {
        address multisig = makeAddr("multisig");
        vm.prank(owner);
        jury.transferOwnership(multisig);
        assertEq(jury.owner(), owner); // not yet

        vm.prank(rando);
        vm.expectRevert(FriendJury.NotPendingOwner.selector);
        jury.acceptOwnership();

        vm.prank(multisig);
        jury.acceptOwnership();
        assertEq(jury.owner(), multisig);
        assertEq(jury.pendingOwner(), address(0));
    }

    // ------------------------------------------------------------- fuzzing

    /// @dev Whatever the group size and whichever way they all agree, a
    /// unanimous vote settles the market to exactly that outcome.
    function testFuzz_UnanimousAlwaysSettles(uint8 rawCount, bool yes) public {
        uint256 count = bound(uint256(rawCount), 2, jury.MAX_VOTERS());
        address[] memory voters = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            voters[i] = address(uint160(0xA000 + i));
            vm.deal(voters[i], 10 ether);
        }

        vm.prank(owner);
        jury.registerJury(address(market), voters, judge, VOTE_WINDOW);

        // Someone must be on the winning side or `resolve()` correctly voids.
        _stake(voters[0], yes ? PredictionMarket.Side.Yes : PredictionMarket.Side.No, 1 ether);
        vm.warp(resolutionDate);

        for (uint256 i = 0; i < count; i++) {
            vm.prank(voters[i]);
            jury.castVote(address(market), yes ? YES : NO);
        }

        assertEq(uint8(market.state()), uint8(PredictionMarket.State.Resolved));
        assertEq(uint8(market.outcome()), yes ? YES : NO);
    }
}
