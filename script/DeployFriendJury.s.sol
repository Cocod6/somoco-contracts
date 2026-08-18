// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {FriendJury} from "../src/FriendJury.sol";

/// @notice Deploys FriendJury against an already-deployed MarketFactory.
///
/// Nothing changes for existing markets at deploy time — the contract only
/// takes effect once it holds the factory's resolver role, which is a separate,
/// deliberate two-step handover:
///
///   1. From the CURRENT resolver key:
///        cast send <FACTORY> "proposeResolver(address)" <JURY> --account <resolver>
///   2. From anyone (it only succeeds if step 1 named this exact contract):
///        cast send <JURY> "acceptResolverRole()" --account <any>
///
/// Reversing it is the same shape, from the jury's owner:
///        cast send <JURY> "handBackResolverRole(address)" <EOA> --account <owner>
///        cast send <FACTORY> "acceptResolver()" --account <EOA>
///
/// Required env vars:
///   FACTORY — the live MarketFactory this jury resolves for
///   OWNER   — Somoco admin (registers juries, resolves ordinary markets)
///
/// Mainnet: forge script script/DeployFriendJury.s.sol --rpc-url intuition --broadcast
contract DeployFriendJury is Script {
    function run() external {
        address factoryAddr = vm.envAddress("FACTORY");
        address ownerAddr = vm.envAddress("OWNER");

        vm.startBroadcast();
        FriendJury jury = new FriendJury(factoryAddr, ownerAddr);
        vm.stopBroadcast();

        console.log("FriendJury:", address(jury));
        console.log("Factory:   ", factoryAddr);
        console.log("Owner:     ", ownerAddr);
        console.log("");
        console.log("NOT live yet. Hand over the resolver role in two steps:");
        console.log("  1) cast send <FACTORY> 'proposeResolver(address)' <JURY> --account <resolver>");
        console.log("  2) cast send <JURY> 'acceptResolverRole()' --account <any>");
    }
}
