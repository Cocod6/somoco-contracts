// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {MarketFactory} from "../src/MarketFactory.sol";

/// @notice Deploys MarketFactory (which deploys the PredictionMarket
/// implementation in its constructor).
///
/// Required env vars — these are the real trust decisions from §10 of the
/// spec; do NOT point them at a single hot wallet in production:
///   OWNER      — admin multisig (creates markets, sets treasury/minStake)
///   RESOLVER   — resolver multisig (declares outcomes)
///   TREASURY   — fee-receiving multisig (separate from resolver)
///   MIN_STAKE  — minimum stake in wei (e.g. 1e18 = 1 TRUST)
///
/// Testnet:  forge script script/Deploy.s.sol --rpc-url <testnet> --broadcast
/// Mainnet:  forge script script/Deploy.s.sol --rpc-url intuition --broadcast
contract Deploy is Script {
    function run() external {
        address ownerAddr = vm.envAddress("OWNER");
        address resolverAddr = vm.envAddress("RESOLVER");
        address treasuryAddr = vm.envAddress("TREASURY");
        uint256 minStake = vm.envUint("MIN_STAKE");

        vm.startBroadcast();
        MarketFactory factory = new MarketFactory(ownerAddr, resolverAddr, treasuryAddr, minStake);
        vm.stopBroadcast();

        console.log("MarketFactory:  ", address(factory));
        console.log("Implementation: ", factory.implementation());
        console.log("Owner:          ", ownerAddr);
        console.log("Resolver:       ", resolverAddr);
        console.log("Treasury:       ", treasuryAddr);
        console.log("Min stake (wei):", minStake);
    }
}
