// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {MarketFactory} from "../src/MarketFactory.sol";
import {PredictionMarket} from "../src/PredictionMarket.sol";

/// @dev Malicious receiver that re-enters `claim()` from its receive hook.
contract ReentrantClaimer {
    PredictionMarket public market;
    bool public attack;

    constructor(PredictionMarket market_) {
        market = market_;
    }

    function stakeYes() external payable {
        market.stake{value: msg.value}(PredictionMarket.Side.Yes);
    }

    function doClaim(bool attack_) external {
        attack = attack_;
        market.claim();
    }

    receive() external payable {
        if (attack) {
            attack = false;
            market.claim(); // must revert -> whole outer claim reverts
        }
    }
}

/// @dev A contract with no receive/fallback — any plain transfer to it reverts.
contract NoReceive {}

/// @dev Receiver that rejects funds, to exercise TransferFailed.
contract RejectingReceiver {
    PredictionMarket public market;

    constructor(PredictionMarket market_) {
        market = market_;
    }

    function stakeYes() external payable {
        market.stake{value: msg.value}(PredictionMarket.Side.Yes);
    }

    function doClaim() external {
        market.claim();
    }
    // no receive() -> transfers to this contract revert
}

contract PredictionMarketTest is Test {
    MarketFactory factory;
    PredictionMarket market;

    address owner = makeAddr("owner");
    address resolver = makeAddr("resolver");
    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address rando = makeAddr("rando");
    address predCreator = makeAddr("predCreator");

    bytes32 constant TERM_ID = bytes32(uint256(0xbeef));
    uint256 constant MIN_STAKE = 0.01 ether;
    uint64 constant LOCK_OFFSET = 24 hours;

    uint64 resolutionDate;
    uint64 lockAt;

    function setUp() public {
        vm.warp(1_800_000_000); // fixed, realistic timestamp
        factory = new MarketFactory(owner, resolver, treasury, MIN_STAKE);

        resolutionDate = uint64(block.timestamp + 7 days);
        lockAt = resolutionDate - LOCK_OFFSET;

        vm.prank(owner);
        market = PredictionMarket(factory.createMarket(TERM_ID, resolutionDate, LOCK_OFFSET, predCreator));

        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
        vm.deal(carol, 1000 ether);
        vm.deal(rando, 1000 ether);
    }

    // ------------------------------------------------------------- helpers

    function _stake(address who, PredictionMarket.Side side, uint256 amount) internal {
        vm.prank(who);
        market.stake{value: amount}(side);
    }

    function _lock() internal {
        vm.warp(lockAt);
    }

    function _resolve(PredictionMarket.Outcome o) internal {
        _lock();
        vm.prank(resolver);
        market.resolve(o);
    }

    // ------------------------------------------------------ initialization

    function test_InitializeStoredConfig() public view {
        assertEq(market.termId(), TERM_ID);
        assertEq(market.resolutionDate(), resolutionDate);
        assertEq(market.lockAt(), lockAt);
        assertEq(market.minStake(), MIN_STAKE);
        assertEq(market.factory(), address(factory));
        assertEq(uint8(market.state()), uint8(PredictionMarket.State.Open));
    }

    function test_RevertWhen_InitializeCalledTwice() public {
        vm.expectRevert(PredictionMarket.AlreadyInitialized.selector);
        market.initialize(TERM_ID, resolutionDate, lockAt, MIN_STAKE, predCreator, 50);
    }

    function test_RevertWhen_InitializeImplementation() public {
        PredictionMarket impl = PredictionMarket(factory.implementation());
        vm.expectRevert(PredictionMarket.AlreadyInitialized.selector);
        impl.initialize(TERM_ID, resolutionDate, lockAt, MIN_STAKE, predCreator, 50);
    }

    // -------------------------------------------------------------- staking

    function test_StakeAccumulatesAndEmits() public {
        vm.expectEmit(true, false, false, true);
        emit PredictionMarket.Staked(alice, PredictionMarket.Side.Yes, 1 ether);
        _stake(alice, PredictionMarket.Side.Yes, 1 ether);
        _stake(alice, PredictionMarket.Side.Yes, 2 ether);
        assertEq(market.stakeYes(alice), 3 ether);
        assertEq(market.poolYes(), 3 ether);
    }

    function test_StakeBothSidesAllowed() public {
        _stake(alice, PredictionMarket.Side.Yes, 1 ether);
        _stake(alice, PredictionMarket.Side.No, 2 ether);
        assertEq(market.stakeYes(alice), 1 ether);
        assertEq(market.stakeNo(alice), 2 ether);
    }

    function test_RevertWhen_StakeBelowMinimum() public {
        vm.prank(alice);
        vm.expectRevert(PredictionMarket.BelowMinStake.selector);
        market.stake{value: MIN_STAKE - 1}(PredictionMarket.Side.Yes);
    }

    function test_RevertWhen_StakeAfterLock() public {
        _lock();
        assertEq(uint8(market.state()), uint8(PredictionMarket.State.Locked));
        vm.prank(alice);
        vm.expectRevert(PredictionMarket.StakingClosed.selector);
        market.stake{value: 1 ether}(PredictionMarket.Side.Yes);
    }

    function test_RevertWhen_StakeAfterResolve() public {
        _stake(alice, PredictionMarket.Side.Yes, 1 ether);
        _stake(bob, PredictionMarket.Side.No, 1 ether);
        _resolve(PredictionMarket.Outcome.Yes);
        vm.prank(carol);
        vm.expectRevert(PredictionMarket.StakingClosed.selector);
        market.stake{value: 1 ether}(PredictionMarket.Side.No);
    }

    // ----------------------------------------------------------- resolution

    function test_RevertWhen_ResolveBeforeLock() public {
        _stake(alice, PredictionMarket.Side.Yes, 1 ether);
        _stake(bob, PredictionMarket.Side.No, 1 ether);
        vm.prank(resolver);
        vm.expectRevert(PredictionMarket.NotLocked.selector);
        market.resolve(PredictionMarket.Outcome.Yes);
    }

    function test_RevertWhen_ResolveTwice() public {
        _stake(alice, PredictionMarket.Side.Yes, 1 ether);
        _stake(bob, PredictionMarket.Side.No, 1 ether);
        _resolve(PredictionMarket.Outcome.Yes);
        vm.prank(resolver);
        vm.expectRevert(PredictionMarket.NotLocked.selector);
        market.resolve(PredictionMarket.Outcome.No);
    }

    function test_RevertWhen_ResolveByNonResolver() public {
        _stake(alice, PredictionMarket.Side.Yes, 1 ether);
        _stake(bob, PredictionMarket.Side.No, 1 ether);
        _lock();
        vm.prank(rando);
        vm.expectRevert(PredictionMarket.NotResolver.selector);
        market.resolve(PredictionMarket.Outcome.Yes);
    }

    function test_RevertWhen_ResolveUnresolved() public {
        _stake(alice, PredictionMarket.Side.Yes, 1 ether);
        _stake(bob, PredictionMarket.Side.No, 1 ether);
        _lock();
        vm.prank(resolver);
        vm.expectRevert(PredictionMarket.InvalidOutcome.selector);
        market.resolve(PredictionMarket.Outcome.Unresolved);
    }

    function test_ResolverHandoverAppliesToExistingMarket() public {
        _stake(alice, PredictionMarket.Side.Yes, 1 ether);
        _stake(bob, PredictionMarket.Side.No, 1 ether);

        address newResolver = makeAddr("newResolver");
        vm.prank(resolver);
        factory.proposeResolver(newResolver);
        vm.prank(newResolver);
        factory.acceptResolver();

        _lock();
        vm.prank(resolver); // old resolver now rejected
        vm.expectRevert(PredictionMarket.NotResolver.selector);
        market.resolve(PredictionMarket.Outcome.Yes);

        vm.prank(newResolver);
        market.resolve(PredictionMarket.Outcome.Yes);
        assertEq(uint8(market.state()), uint8(PredictionMarket.State.Resolved));
    }

    // -------------------------------------------------- payout math (§5)

    /// The exact worked example from the spec:
    /// poolYes = 100, poolNo = 100, YES wins, alice staked 10 on YES.
    /// fee = 3, distributed = 97, alice's payout = 10 + 10*97/100 = 19.7.
    /// The 3 fee splits 0.5% creator / 2.5% treasury and auto-distributes
    /// at resolution.
    function test_WorkedExampleFromSpec() public {
        _stake(alice, PredictionMarket.Side.Yes, 10 ether);
        _stake(bob, PredictionMarket.Side.Yes, 90 ether);
        _stake(carol, PredictionMarket.Side.No, 100 ether);

        _resolve(PredictionMarket.Outcome.Yes);
        assertEq(market.feeAmount(), 3 ether);

        // Fee auto-distributed at resolve: creator 0.5% of 100, treasury the rest.
        assertEq(predCreator.balance, 0.5 ether);
        assertEq(treasury.balance, 2.5 ether);

        assertEq(market.claimableOf(alice), 19.7 ether);
        assertEq(market.claimableOf(bob), 177.3 ether);
        assertEq(market.claimableOf(carol), 0);

        uint256 before = alice.balance;
        vm.prank(alice);
        market.claim();
        assertEq(alice.balance - before, 19.7 ether);

        vm.prank(bob);
        market.claim();

        // 19.7 + 177.3 + 0.5 + 2.5 = 200: everything accounted for, zero dust.
        assertEq(address(market).balance, 0);
    }

    function test_FullLifecycleNoWins() public {
        _stake(alice, PredictionMarket.Side.Yes, 40 ether);
        _stake(bob, PredictionMarket.Side.No, 10 ether);
        _stake(carol, PredictionMarket.Side.No, 30 ether);

        _resolve(PredictionMarket.Outcome.No);
        // losing pool 40, fee 1.2, distributed 38.8
        assertEq(market.feeAmount(), 1.2 ether);
        // bob: 10 + 10*38.8/40 = 19.7 ; carol: 30 + 30*38.8/40 = 59.1
        assertEq(market.claimableOf(bob), 19.7 ether);
        assertEq(market.claimableOf(carol), 59.1 ether);
        assertEq(market.claimableOf(alice), 0);

        vm.prank(alice);
        vm.expectRevert(PredictionMarket.NothingToClaim.selector);
        market.claim();
    }

    function test_BothSidesStakerPaidOnlyWinningSide() public {
        _stake(alice, PredictionMarket.Side.Yes, 10 ether);
        _stake(alice, PredictionMarket.Side.No, 10 ether);
        _stake(bob, PredictionMarket.Side.No, 10 ether);

        _resolve(PredictionMarket.Outcome.Yes);
        // losing pool 20, fee 0.6, distributed 19.4, alice is 100% of YES pool
        assertEq(market.claimableOf(alice), 10 ether + 19.4 ether);
    }

    function test_WinnerNeverReceivesLessThanStake_Fuzz(uint96 yesA, uint96 yesB, uint96 no) public {
        uint256 a = bound(uint256(yesA), MIN_STAKE, 500 ether);
        uint256 b = bound(uint256(yesB), MIN_STAKE, 500 ether);
        uint256 n = bound(uint256(no), MIN_STAKE, 500 ether);

        _stake(alice, PredictionMarket.Side.Yes, a);
        _stake(bob, PredictionMarket.Side.Yes, b);
        _stake(carol, PredictionMarket.Side.No, n);

        _resolve(PredictionMarket.Outcome.Yes);
        assertGe(market.claimableOf(alice), a, "winner got back less than staked");
        assertGe(market.claimableOf(bob), b, "winner got back less than staked");
    }

    // ------------------------------------------- one-sided / empty markets

    function test_ResolveWithEmptyLosingPoolRefundsWinners() public {
        // Only the winning side has stakers: NOT a void. Winners get their
        // stake back via the normal payout, with zero fee (empty losing pool).
        _stake(alice, PredictionMarket.Side.Yes, 10 ether);
        _resolve(PredictionMarket.Outcome.Yes); // no NO stakers

        assertEq(uint8(market.state()), uint8(PredictionMarket.State.Resolved));
        assertEq(market.claimableOf(alice), 10 ether);
        assertEq(market.feeAmount(), 0); // fee-free

        vm.prank(alice);
        market.claim();
        assertEq(address(market).balance, 0);
    }

    function test_ResolveWithEmptyWinningPoolVoids() public {
        _stake(carol, PredictionMarket.Side.No, 10 ether);
        _resolve(PredictionMarket.Outcome.Yes); // everyone was wrong -> refund, not treasury

        assertEq(uint8(market.state()), uint8(PredictionMarket.State.Voided));
        assertEq(market.claimableOf(carol), 10 ether);
    }

    function test_ResolveEmptyMarketVoids() public {
        _resolve(PredictionMarket.Outcome.Yes);
        assertEq(uint8(market.state()), uint8(PredictionMarket.State.Voided));
    }

    // ---------------------------------------------------- early unstake (§6)

    function test_UnstakeReturns60PercentAndEmits() public {
        _stake(alice, PredictionMarket.Side.Yes, 10 ether);
        assertEq(market.poolYes(), 10 ether);

        uint256 before = alice.balance;
        vm.expectEmit(true, false, false, true);
        emit PredictionMarket.Unstaked(alice, PredictionMarket.Side.Yes, 10 ether, 6 ether, 4 ether);
        vm.prank(alice);
        market.unstake(PredictionMarket.Side.Yes);

        assertEq(alice.balance - before, 6 ether); // keeps 60%
        assertEq(market.stakeYes(alice), 0);
        assertEq(market.poolYes(), 0);
        assertEq(market.forfeitPool(), 4 ether); // 40% stays in the pot
        // invariant: balance == poolYes + poolNo + forfeitPool
        assertEq(address(market).balance, market.poolYes() + market.poolNo() + market.forfeitPool());
    }

    function test_ForfeitBoostsTheWinningSide() public {
        // Alice & Bob on YES, Carol on NO. Alice bails, forfeiting 4.
        _stake(alice, PredictionMarket.Side.Yes, 10 ether);
        _stake(bob, PredictionMarket.Side.Yes, 10 ether);
        _stake(carol, PredictionMarket.Side.No, 20 ether);

        vm.prank(alice);
        market.unstake(PredictionMarket.Side.Yes); // forfeit 4 -> forfeitPool
        assertEq(market.forfeitPool(), 4 ether);
        assertEq(market.poolYes(), 10 ether); // only Bob left on YES

        _resolve(PredictionMarket.Outcome.Yes);
        // losingPool 20, fee 0.6, distributed = (20 - 0.6) + 4 = 23.4
        // Bob (sole YES winner) = 10 + 10*23.4/10 = 33.4
        assertEq(market.claimableOf(bob), 33.4 ether);
        assertEq(market.claimableOf(alice), 0); // she left
        assertEq(market.claimableOf(carol), 0); // lost

        uint256 before = bob.balance;
        vm.prank(bob);
        market.claim();
        assertEq(bob.balance - before, 33.4 ether);
        assertEq(address(market).balance, 0); // fully settled
    }

    function test_UnstakeBothSidesIndependently() public {
        _stake(alice, PredictionMarket.Side.Yes, 10 ether);
        _stake(alice, PredictionMarket.Side.No, 5 ether);

        vm.prank(alice);
        market.unstake(PredictionMarket.Side.Yes);
        assertEq(market.stakeYes(alice), 0);
        assertEq(market.stakeNo(alice), 5 ether); // NO position untouched
        assertEq(market.forfeitPool(), 4 ether);

        vm.prank(alice);
        market.unstake(PredictionMarket.Side.No);
        assertEq(market.stakeNo(alice), 0);
        assertEq(market.forfeitPool(), 4 ether + 2 ether);
    }

    function test_RevertWhen_UnstakeAfterLock() public {
        _stake(alice, PredictionMarket.Side.Yes, 10 ether);
        _lock();
        vm.prank(alice);
        vm.expectRevert(PredictionMarket.StakingClosed.selector);
        market.unstake(PredictionMarket.Side.Yes);
    }

    function test_RevertWhen_UnstakeNothing() public {
        vm.prank(rando);
        vm.expectRevert(PredictionMarket.NothingStaked.selector);
        market.unstake(PredictionMarket.Side.Yes);
    }

    function test_UnstakeThenRestakeWorks() public {
        _stake(alice, PredictionMarket.Side.Yes, 10 ether);
        vm.prank(alice);
        market.unstake(PredictionMarket.Side.Yes);
        // can stake again after exiting
        _stake(alice, PredictionMarket.Side.Yes, 5 ether);
        assertEq(market.stakeYes(alice), 5 ether);
        assertEq(market.poolYes(), 5 ether);
    }

    function test_AllWinnersUnstakeThenResolveVoids() public {
        // Both YES stakers bail; YES then wins with no one left -> void.
        _stake(alice, PredictionMarket.Side.Yes, 10 ether);
        _stake(bob, PredictionMarket.Side.Yes, 10 ether);
        _stake(carol, PredictionMarket.Side.No, 20 ether);

        vm.prank(alice);
        market.unstake(PredictionMarket.Side.Yes);
        vm.prank(bob);
        market.unstake(PredictionMarket.Side.Yes);
        assertEq(market.poolYes(), 0);

        _resolve(PredictionMarket.Outcome.Yes); // winningPool empty -> void
        assertEq(uint8(market.state()), uint8(PredictionMarket.State.Voided));
        assertEq(market.claimableOf(carol), 20 ether); // refunded
        // forfeit pot (8) has no rightful winner; stays for the dust sweep
        assertEq(market.forfeitPool(), 8 ether);
    }

    // ------------------------------------------------------ void & timeout

    function test_VoidRefundsExactAndFeeFree() public {
        _stake(alice, PredictionMarket.Side.Yes, 7 ether);
        _stake(alice, PredictionMarket.Side.No, 3 ether);
        _stake(bob, PredictionMarket.Side.No, 5 ether);

        vm.prank(resolver);
        market.void(); // reachable from Open

        assertEq(market.claimableOf(alice), 10 ether);
        assertEq(market.claimableOf(bob), 5 ether);

        uint256 beforeA = alice.balance;
        vm.prank(alice);
        market.claim();
        assertEq(alice.balance - beforeA, 10 ether);

        vm.prank(bob);
        market.claim();
        assertEq(address(market).balance, 0); // zero fee taken
        assertEq(treasury.balance, 0);
    }

    function test_VoidReachableFromLocked() public {
        _stake(alice, PredictionMarket.Side.Yes, 1 ether);
        _lock();
        vm.prank(resolver);
        market.void();
        assertEq(uint8(market.state()), uint8(PredictionMarket.State.Voided));
    }

    function test_RevertWhen_VoidByNonResolver() public {
        vm.prank(rando);
        vm.expectRevert(PredictionMarket.NotResolver.selector);
        market.void();
    }

    function test_RevertWhen_VoidAfterResolved() public {
        _stake(alice, PredictionMarket.Side.Yes, 1 ether);
        _stake(bob, PredictionMarket.Side.No, 1 ether);
        _resolve(PredictionMarket.Outcome.Yes);
        vm.prank(resolver);
        vm.expectRevert(PredictionMarket.AlreadyFinal.selector);
        market.void();
    }

    function test_RevertWhen_VoidAfterTimeoutTooEarly() public {
        _stake(alice, PredictionMarket.Side.Yes, 1 ether);
        vm.warp(uint256(resolutionDate) + market.RESOLUTION_TIMEOUT()); // exactly at boundary: still too early
        vm.prank(rando);
        vm.expectRevert(PredictionMarket.TimeoutNotReached.selector);
        market.voidAfterTimeout();
    }

    function test_VoidAfterTimeoutByAnyone() public {
        _stake(alice, PredictionMarket.Side.Yes, 4 ether);
        _stake(bob, PredictionMarket.Side.No, 6 ether);

        vm.warp(uint256(resolutionDate) + market.RESOLUTION_TIMEOUT() + 1);
        vm.prank(rando); // permissionless by design
        market.voidAfterTimeout();

        assertEq(uint8(market.state()), uint8(PredictionMarket.State.Voided));
        assertEq(market.claimableOf(alice), 4 ether);
        assertEq(market.claimableOf(bob), 6 ether);
    }

    function test_RevertWhen_VoidAfterTimeoutOnResolvedMarket() public {
        _stake(alice, PredictionMarket.Side.Yes, 1 ether);
        _stake(bob, PredictionMarket.Side.No, 1 ether);
        _resolve(PredictionMarket.Outcome.Yes);
        vm.warp(uint256(resolutionDate) + market.RESOLUTION_TIMEOUT() + 1);
        vm.prank(rando);
        vm.expectRevert(PredictionMarket.AlreadyFinal.selector);
        market.voidAfterTimeout();
    }

    // ------------------------------------------------------------- claiming

    function test_RevertWhen_ClaimBeforeFinal() public {
        _stake(alice, PredictionMarket.Side.Yes, 1 ether);
        vm.prank(alice);
        vm.expectRevert(PredictionMarket.NotClaimable.selector);
        market.claim();

        _lock(); // Locked is still not claimable
        vm.prank(alice);
        vm.expectRevert(PredictionMarket.NotClaimable.selector);
        market.claim();
    }

    function test_RevertWhen_DoubleClaim() public {
        _stake(alice, PredictionMarket.Side.Yes, 1 ether);
        _stake(bob, PredictionMarket.Side.No, 1 ether);
        _resolve(PredictionMarket.Outcome.Yes);

        vm.prank(alice);
        market.claim();
        assertEq(market.claimableOf(alice), 0);

        vm.prank(alice);
        vm.expectRevert(PredictionMarket.AlreadyClaimed.selector);
        market.claim();
    }

    function test_ReentrantClaimReverts() public {
        ReentrantClaimer attacker = new ReentrantClaimer(market);
        vm.deal(address(this), 10 ether);
        attacker.stakeYes{value: 5 ether}();
        _stake(bob, PredictionMarket.Side.No, 5 ether);

        _resolve(PredictionMarket.Outcome.Yes);

        // Re-entering claim() hits nonReentrant -> receive() reverts -> the
        // payout transfer fails -> the whole outer claim reverts. No funds move.
        vm.expectRevert(PredictionMarket.TransferFailed.selector);
        attacker.doClaim(true);
        assertEq(address(attacker).balance, 0);
        assertFalse(market.claimed(address(attacker)));

        // Without the attack the same contract claims normally, exactly once.
        attacker.doClaim(false);
        assertGt(address(attacker).balance, 5 ether);
    }

    function test_RejectingReceiverDoesNotBlockOthers() public {
        // Pull payments: one reverting recipient must not affect anyone else.
        RejectingReceiver rejector = new RejectingReceiver(market);
        vm.deal(address(this), 10 ether);
        rejector.stakeYes{value: 5 ether}();
        _stake(alice, PredictionMarket.Side.Yes, 5 ether);
        _stake(bob, PredictionMarket.Side.No, 10 ether);

        _resolve(PredictionMarket.Outcome.Yes);

        vm.expectRevert(PredictionMarket.TransferFailed.selector);
        rejector.doClaim();

        vm.prank(alice); // alice is unaffected
        market.claim();
    }

    // ------------------------------------------------------------- sweeping

    function test_FeesAutoDistributedAtResolve() public {
        _stake(alice, PredictionMarket.Side.Yes, 10 ether);
        _stake(bob, PredictionMarket.Side.No, 10 ether);
        _resolve(PredictionMarket.Outcome.Yes);

        // losing pool 10 -> fee 0.3: creator 0.05 (0.5%), treasury 0.25 (2.5%)
        assertEq(predCreator.balance, 0.05 ether);
        assertEq(treasury.balance, 0.25 ether);
        assertTrue(market.feeSwept());
        assertTrue(market.creatorFeeSettled());

        // nothing left to sweep — auto-distribution already happened
        vm.expectRevert(PredictionMarket.NothingToSweep.selector);
        market.sweepFee();
    }

    function test_RevertingCreatorForfeitsToTreasury() public {
        // A creator that can't receive native token forfeits its slice.
        address badCreator = address(new NoReceive());
        bytes32 term2 = bytes32(uint256(0xbeef2));
        vm.prank(owner);
        PredictionMarket m2 = PredictionMarket(factory.createMarket(term2, resolutionDate, LOCK_OFFSET, badCreator));

        vm.prank(alice);
        m2.stake{value: 10 ether}(PredictionMarket.Side.Yes);
        vm.prank(bob);
        m2.stake{value: 10 ether}(PredictionMarket.Side.No);

        vm.warp(lockAt);
        vm.prank(resolver);
        m2.resolve(PredictionMarket.Outcome.Yes);

        // creator slice (0.05) folded into treasury: 0.25 + 0.05 = 0.3
        assertEq(badCreator.balance, 0);
        assertEq(treasury.balance, 0.3 ether);
        assertTrue(m2.feeSwept());
    }

    function test_RevertingTreasuryRetriedViaSweepFee() public {
        // Treasury that can't receive: auto-distribution pays the creator but
        // leaves the treasury slice pending; resolution itself is NOT blocked.
        address badTreasury = address(new NoReceive());
        vm.prank(owner);
        factory.setTreasury(badTreasury);

        _stake(alice, PredictionMarket.Side.Yes, 10 ether);
        _stake(bob, PredictionMarket.Side.No, 10 ether);
        _resolve(PredictionMarket.Outcome.Yes);

        assertEq(predCreator.balance, 0.05 ether); // creator still paid
        assertFalse(market.feeSwept());            // treasury slice pending

        // Fix the treasury, retry permissionlessly.
        vm.prank(owner);
        factory.setTreasury(treasury);
        market.sweepFee();
        assertEq(treasury.balance, 0.25 ether);
        assertTrue(market.feeSwept());
    }

    function test_RevertWhen_SweepFeeOnVoided() public {
        _stake(alice, PredictionMarket.Side.Yes, 10 ether);
        vm.prank(resolver);
        market.void();
        vm.expectRevert(PredictionMarket.NotResolved.selector);
        market.sweepFee();
    }

    function test_SweepDustAfterGrace() public {
        _stake(alice, PredictionMarket.Side.Yes, 10 ether);
        _stake(bob, PredictionMarket.Side.No, 10 ether);
        _resolve(PredictionMarket.Outcome.Yes);
        // fee (0.3) auto-distributed at resolve; alice never claims her 19.7

        vm.expectRevert(PredictionMarket.GraceNotOver.selector);
        market.sweepDust();

        vm.warp(uint256(market.finalizedAt()) + market.DUST_GRACE());
        uint256 treasuryBefore = treasury.balance;
        uint256 remaining = address(market).balance;
        assertEq(remaining, 19.7 ether); // the unclaimed payout
        market.sweepDust();
        assertEq(treasury.balance - treasuryBefore, remaining);
        assertEq(address(market).balance, 0);

        vm.expectRevert(PredictionMarket.NothingToSweep.selector);
        market.sweepFee();
    }

    // ------------------------------------------------- solvency invariant

    /// §11: sum of all outstanding claims + unswept fee never exceeds balance,
    /// and every claim actually succeeds (nobody's payout reverts for
    /// insufficient funds) across arbitrary stake AND unstake sequences.
    function test_SolvencyInvariant_Fuzz(
        uint96[8] memory amounts,
        bool[8] memory sides,
        bool[8] memory bails,
        bool yesWins
    ) public {
        address[8] memory users;
        for (uint256 i; i < 8; i++) {
            users[i] = address(uint160(0x5000 + i));
            vm.deal(users[i], 600 ether);
            uint256 amt = bound(uint256(amounts[i]), MIN_STAKE, 500 ether);
            PredictionMarket.Side side = sides[i] ? PredictionMarket.Side.Yes : PredictionMarket.Side.No;
            _stake(users[i], side, amt);
        }

        // Some users bail early (40% penalty) before the market locks.
        for (uint256 i; i < 8; i++) {
            if (!bails[i]) continue;
            PredictionMarket.Side side = sides[i] ? PredictionMarket.Side.Yes : PredictionMarket.Side.No;
            vm.prank(users[i]);
            market.unstake(side);
        }

        // Invariant holds continuously: balance == poolYes + poolNo + forfeitPool
        assertEq(address(market).balance, market.poolYes() + market.poolNo() + market.forfeitPool(), "pre-resolve");

        uint256 winners; // count remaining stakers on the winning side
        for (uint256 i; i < 8; i++) {
            bool onWinningSide = (sides[i] == yesWins);
            uint256 remaining = yesWins ? market.stakeYes(users[i]) : market.stakeNo(users[i]);
            if (onWinningSide && remaining > 0) winners++;
        }

        _resolve(yesWins ? PredictionMarket.Outcome.Yes : PredictionMarket.Outcome.No);

        if (winners == 0) {
            // no one left on the winning side -> voided
            assertEq(uint8(market.state()), uint8(PredictionMarket.State.Voided));
        }

        // Fees (both slices) auto-distribute at resolve, so the remaining
        // balance must cover exactly the sum of outstanding claims.
        uint256 totalClaims;
        for (uint256 i; i < 8; i++) {
            totalClaims += market.claimableOf(users[i]);
        }
        assertLe(totalClaims, address(market).balance, "insolvent");

        // On a real resolution the fee splits must be fully settled.
        if (uint8(market.state()) == uint8(PredictionMarket.State.Resolved)) {
            assertTrue(market.creatorFeeSettled() || market.creatorFeeAmount() == 0);
            assertTrue(market.feeSwept() || market.feeAmount() == 0);
            assertEq(predCreator.balance, market.creatorFeeAmount());
        }

        // Every non-zero claim succeeds; claimed sum matches predictions.
        for (uint256 i; i < 8; i++) {
            uint256 expect = market.claimableOf(users[i]);
            if (expect == 0) continue;
            uint256 before = users[i].balance;
            vm.prank(users[i]);
            market.claim();
            assertEq(users[i].balance - before, expect);
        }

        if (uint8(market.state()) == uint8(PredictionMarket.State.Voided)) {
            // Void refunds every active stake exactly; the forfeit pot has no
            // rightful winner and is left in the contract for the dust sweep.
            assertEq(address(market).balance, market.forfeitPool(), "void residual != forfeit pot");
        } else {
            // Resolved: forfeit pot was distributed to winners, so only
            // rounding dust remains (< 1 wei per winner's truncated division).
            assertLt(address(market).balance, 8, "too much dust left");
        }
    }

    // -------------------------------------------------------- misc guards

    function test_NoStrayNativeTransfers() public {
        // No receive/fallback: plain sends must bounce, so pool accounting
        // always matches the balance.
        vm.prank(alice);
        (bool ok,) = address(market).call{value: 1 ether}("");
        assertFalse(ok);
    }
}
