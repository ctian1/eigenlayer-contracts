// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.12;

import "forge-std/Test.sol";

import "src/contracts/core/DelegationManager.sol";
import "src/contracts/core/StrategyManager.sol";
import "src/contracts/pods/EigenPodManager.sol";

contract Global is Test {
    // Cheats
    Vm cheats = Vm(HEVM_ADDRESS);
    
    // Snapshot vars
    bool pastExists = false;
    uint lastSnapshot;

    // Constants
    DelegationManager public delegationManager;
    StrategyManager public strategyManager;
    EigenPodManager public eigenPodManager;

    constructor(
        DelegationManager _delegationManager,
        StrategyManager _strategyManager,
        EigenPodManager _eigenPodManager) 
    {
        delegationManager = _delegationManager;
        strategyManager = _strategyManager;
        eigenPodManager = _eigenPodManager;
    }

    function createSnapshot() public returns (uint) {
        uint snapshot = cheats.snapshot();
        lastSnapshot = snapshot;
        pastExists = true;
        return snapshot;
    }

    function warpToLast() public returns (uint curState) {
        // Safety check to make sure createSnapshot is called before attempting to warp
        // so we don't accidentally prevent our own births
        assertTrue(pastExists, "Global.warpToPast: invalid usage, past does not exist");

        curState = cheats.snapshot();
        cheats.revertTo(lastSnapshot);
        return curState;
    }

    function warpToPresent(uint curState) public {
        cheats.revertTo(curState);
    }
}