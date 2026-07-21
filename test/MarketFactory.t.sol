// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MarketFactory} from "../src/MarketFactory.sol";
import {PredictionMarket} from "../src/PredictionMarket.sol";

contract MarketFactoryTest is Test {
    MarketFactory factory;

    address owner = makeAddr("owner");
    address resolver = makeAddr("resolver");
    address treasury = makeAddr("treasury");
    address rando = makeAddr("rando");
    address predCreator = makeAddr("predCreator");

    bytes32 constant TERM_A = bytes32(uint256(0xaaaa));
    bytes32 constant TERM_B = bytes32(uint256(0xbbbb));
    uint256 constant MIN_STAKE = 0.01 ether;

    uint64 resolutionDate;

    function setUp() public {
        vm.warp(1_800_000_000);
        factory = new MarketFactory(owner, resolver, treasury, MIN_STAKE);
        resolutionDate = uint64(block.timestamp + 7 days);
    }

    // ------------------------------------------------------------- creation

    function test_CreateMarketRegistersAndInitializes() public {
        vm.prank(owner);
        address market = factory.createMarket(TERM_A, resolutionDate, 24 hours, predCreator);

        assertEq(factory.marketForTerm(TERM_A), market);
        assertEq(factory.marketCount(), 1);
        assertEq(factory.allMarkets(0), market);

        PredictionMarket m = PredictionMarket(market);
        assertEq(m.termId(), TERM_A);
        assertEq(m.lockAt(), resolutionDate - 24 hours);
        assertEq(m.minStake(), MIN_STAKE);
    }

    function test_RevertWhen_CreateByNonOwner() public {
        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, rando));
        factory.createMarket(TERM_A, resolutionDate, 24 hours, predCreator);
    }

    function test_RevertWhen_DuplicateTermId() public {
        vm.startPrank(owner);
        factory.createMarket(TERM_A, resolutionDate, 24 hours, predCreator);
        vm.expectRevert(MarketFactory.DuplicateMarket.selector);
        factory.createMarket(TERM_A, resolutionDate, 24 hours, predCreator);
        vm.stopPrank();
    }

    function test_RevertWhen_ZeroTermId() public {
        vm.prank(owner);
        vm.expectRevert(MarketFactory.InvalidTermId.selector);
        factory.createMarket(bytes32(0), resolutionDate, 24 hours, predCreator);
    }

    function test_RevertWhen_ResolutionInPast() public {
        vm.prank(owner);
        vm.expectRevert(MarketFactory.ResolutionInPast.selector);
        factory.createMarket(TERM_A, uint64(block.timestamp), 0, predCreator);
    }

    function test_RevertWhen_LockAlreadyPassed() public {
        // resolution is tomorrow but the lock offset puts lockAt in the past
        vm.prank(owner);
        vm.expectRevert(MarketFactory.InvalidLockOffset.selector);
        factory.createMarket(TERM_A, uint64(block.timestamp + 1 days), 2 days, predCreator);
    }

    function test_TwoMarketsIndependentState() public {
        vm.startPrank(owner);
        address a = factory.createMarket(TERM_A, resolutionDate, 24 hours, predCreator);
        address b = factory.createMarket(TERM_B, resolutionDate, 24 hours, predCreator);
        vm.stopPrank();
        assertTrue(a != b);

        hoax(rando, 10 ether);
        PredictionMarket(a).stake{value: 1 ether}(PredictionMarket.Side.Yes);
        assertEq(PredictionMarket(a).poolYes(), 1 ether);
        assertEq(PredictionMarket(b).poolYes(), 0); // clone storage is isolated
    }

    // ----------------------------------------------------- resolver handover

    function test_ResolverHandoverTwoStep() public {
        address next = makeAddr("next");

        vm.prank(rando);
        vm.expectRevert(MarketFactory.NotResolver.selector);
        factory.proposeResolver(next);

        vm.prank(resolver);
        factory.proposeResolver(next);
        assertEq(factory.resolver(), resolver); // unchanged until accepted

        vm.prank(rando);
        vm.expectRevert(MarketFactory.NotPendingResolver.selector);
        factory.acceptResolver();

        vm.prank(next);
        factory.acceptResolver();
        assertEq(factory.resolver(), next);
        assertEq(factory.pendingResolver(), address(0));
    }

    function test_TypoedProposalIsRecoverable() public {
        // The whole point of two-step: a bad proposal can simply be replaced.
        address typo = makeAddr("typo");
        address real = makeAddr("real");
        vm.startPrank(resolver);
        factory.proposeResolver(typo);
        factory.proposeResolver(real); // overwrite before acceptance
        vm.stopPrank();

        vm.prank(typo);
        vm.expectRevert(MarketFactory.NotPendingResolver.selector);
        factory.acceptResolver();

        vm.prank(real);
        factory.acceptResolver();
        assertEq(factory.resolver(), real);
    }

    // ---------------------------------------------------------------- admin

    function test_SetTreasury() public {
        address next = makeAddr("nextTreasury");
        vm.prank(owner);
        factory.setTreasury(next);
        assertEq(factory.treasury(), next);

        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, rando));
        factory.setTreasury(rando);
    }

    function test_RevertWhen_ZeroAddressConfig() public {
        vm.expectRevert(MarketFactory.ZeroAddress.selector);
        new MarketFactory(owner, address(0), treasury, MIN_STAKE);

        vm.prank(owner);
        vm.expectRevert(MarketFactory.ZeroAddress.selector);
        factory.setTreasury(address(0));

        vm.prank(resolver);
        vm.expectRevert(MarketFactory.ZeroAddress.selector);
        factory.proposeResolver(address(0));
    }

    function test_RevertWhen_ZeroCreator() public {
        vm.prank(owner);
        vm.expectRevert(MarketFactory.ZeroAddress.selector);
        factory.createMarket(TERM_A, resolutionDate, 24 hours, address(0));
    }

    function test_CreatorFeeBpsDefaultAndSnapshot() public {
        assertEq(factory.creatorFeeBps(), 50); // 0.5% default

        vm.startPrank(owner);
        address a = factory.createMarket(TERM_A, resolutionDate, 24 hours, predCreator);
        factory.setCreatorFeeBps(25); // platform grew — creator share reduced
        address b = factory.createMarket(TERM_B, resolutionDate, 24 hours, predCreator);
        vm.stopPrank();

        // existing market keeps its snapshot; new market gets the new value
        assertEq(PredictionMarket(a).creatorFeeBps(), 50);
        assertEq(PredictionMarket(b).creatorFeeBps(), 25);
        assertEq(PredictionMarket(a).creator(), predCreator);
    }

    function test_RevertWhen_CreatorFeeAboveTotalFee() public {
        vm.prank(owner);
        vm.expectRevert(MarketFactory.CreatorFeeTooHigh.selector);
        factory.setCreatorFeeBps(301); // total fee is 300 bps

        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, rando));
        factory.setCreatorFeeBps(25);
    }

    function test_MinStakeSnapshotPerMarket() public {
        vm.startPrank(owner);
        address a = factory.createMarket(TERM_A, resolutionDate, 24 hours, predCreator);
        factory.setMinStake(1 ether);
        address b = factory.createMarket(TERM_B, resolutionDate, 24 hours, predCreator);
        vm.stopPrank();

        // existing market keeps its snapshot; new market gets the new value
        assertEq(PredictionMarket(a).minStake(), MIN_STAKE);
        assertEq(PredictionMarket(b).minStake(), 1 ether);
    }
}
