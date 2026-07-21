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
        market = PredictionMarket(factory.createMarket(TERM_ID, resolutionDate, LOCK_OFFSET));

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
        market.initialize(TERM_ID, resolutionDate, lockAt, MIN_STAKE);
    }

    function test_RevertWhen_InitializeImplementation() public {
        PredictionMarket impl = PredictionMarket(factory.implementation());
        vm.expectRevert(PredictionMarket.AlreadyInitialized.selector);
        impl.initialize(TERM_ID, resolutionDate, lockAt, MIN_STAKE);
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
    function test_WorkedExampleFromSpec() public {
        _stake(alice, PredictionMarket.Side.Yes, 10 ether);
        _stake(bob, PredictionMarket.Side.Yes, 90 ether);
        _stake(carol, PredictionMarket.Side.No, 100 ether);

        _resolve(PredictionMarket.Outcome.Yes);
        assertEq(market.feeAmount(), 3 ether);

        assertEq(market.claimableOf(alice), 19.7 ether);
        assertEq(market.claimableOf(bob), 177.3 ether);
        assertEq(market.claimableOf(carol), 0);

        uint256 before = alice.balance;
        vm.prank(alice);
        market.claim();
        assertEq(alice.balance - before, 19.7 ether);

        vm.prank(bob);
        market.claim();

        // 19.7 + 177.3 + 3 = 200: everything accounted for, zero dust here.
        market.sweepFee();
        assertEq(treasury.balance, 3 ether);
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

    function test_ResolveWithEmptyLosingPoolVoids() public {
        _stake(alice, PredictionMarket.Side.Yes, 10 ether);
        _resolve(PredictionMarket.Outcome.Yes); // no NO stakers -> void

        assertEq(uint8(market.state()), uint8(PredictionMarket.State.Voided));
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

    function test_SweepFeeOnceOnly() public {
        _stake(alice, PredictionMarket.Side.Yes, 10 ether);
        _stake(bob, PredictionMarket.Side.No, 10 ether);
        _resolve(PredictionMarket.Outcome.Yes);

        market.sweepFee();
        assertEq(treasury.balance, 0.3 ether);

        vm.expectRevert(PredictionMarket.NothingToSweep.selector);
        market.sweepFee();
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

        vm.prank(alice);
        market.claim(); // bob (loser) never claims; fee never swept

        vm.expectRevert(PredictionMarket.GraceNotOver.selector);
        market.sweepDust();

        vm.warp(uint256(market.finalizedAt()) + market.DUST_GRACE());
        uint256 remaining = address(market).balance;
        market.sweepDust();
        assertEq(treasury.balance, remaining);
        assertEq(address(market).balance, 0);

        // fee is folded into the dust sweep; sweepFee can't double-pay
        vm.expectRevert(PredictionMarket.NothingToSweep.selector);
        market.sweepFee();
    }

    // ------------------------------------------------- solvency invariant

    /// §11: sum of all outstanding claims + unswept fee never exceeds balance,
    /// and every claim actually succeeds (nobody's payout reverts for
    /// insufficient funds) across arbitrary stake sequences.
    function test_SolvencyInvariant_Fuzz(uint96[8] memory amounts, bool[8] memory sides, bool yesWins) public {
        address[8] memory users;
        bool anyYes;
        bool anyNo;
        for (uint256 i; i < 8; i++) {
            users[i] = address(uint160(0x5000 + i));
            vm.deal(users[i], 600 ether);
            uint256 amt = bound(uint256(amounts[i]), MIN_STAKE, 500 ether);
            PredictionMarket.Side side = sides[i] ? PredictionMarket.Side.Yes : PredictionMarket.Side.No;
            _stake(users[i], side, amt);
            if (sides[i]) anyYes = true;
            else anyNo = true;
        }

        _resolve(yesWins ? PredictionMarket.Outcome.Yes : PredictionMarket.Outcome.No);

        if (!(anyYes && anyNo)) {
            // one-sided -> voided; refunds must be exact
            assertEq(uint8(market.state()), uint8(PredictionMarket.State.Voided));
        }

        // Sum of every claimable + fee must be covered by the balance.
        uint256 totalClaims;
        for (uint256 i; i < 8; i++) {
            totalClaims += market.claimableOf(users[i]);
        }
        assertLe(totalClaims + market.feeAmount(), address(market).balance, "insolvent");

        // Every non-zero claim succeeds; claimed sum matches predictions.
        for (uint256 i; i < 8; i++) {
            uint256 expect = market.claimableOf(users[i]);
            if (expect == 0) continue;
            uint256 before = users[i].balance;
            vm.prank(users[i]);
            market.claim();
            assertEq(users[i].balance - before, expect);
        }

        if (market.feeAmount() > 0 && uint8(market.state()) == uint8(PredictionMarket.State.Resolved)) {
            market.sweepFee();
        }
        // Whatever is left is pure rounding dust: strictly less than 8 wei
        // (at most 1 wei lost per winner's truncated division).
        assertLt(address(market).balance, 8, "too much dust left");
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
