// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.12;

import "@openzeppelin-upgrades/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgrades/contracts/access/OwnableUpgradeable.sol";
import "../interfaces/ISlasher.sol";
import "./DelegationManagerStorage.sol";
import "../permissions/Pausable.sol";
import "../libraries/EIP1271SignatureUtils.sol";

/**
 * @title The interface for the primary delegation contract for EigenLayer.
 * @author Layr Labs, Inc.
 * @notice Terms of Service: https://docs.eigenlayer.xyz/overview/terms-of-service
 * @notice  This is the contract for delegation in EigenLayer. The main functionalities of this contract are
 * - enabling anyone to register as an operator in EigenLayer
 * - allowing operators to specify parameters related to stakers who delegate to them
 * - enabling any staker to delegate its stake to the operator of its choice (a given staker can only delegate to a single operator at a time)
 * - enabling a staker to undelegate its assets from the operator it is delegated to (performed as part of the withdrawal process, initiated through the StrategyManager)
 */
contract DelegationManager is Initializable, OwnableUpgradeable, Pausable, DelegationManagerStorage {
    // index for flag that pauses new delegations when set
    uint8 internal constant PAUSED_NEW_DELEGATION = 0;

    // chain id at the time of contract deployment
    uint256 internal immutable ORIGINAL_CHAIN_ID;

    /**
     * @notice Maximum value that `_operatorDetails[operator].stakerOptOutWindowBlocks` is allowed to take, for any operator.
     * @dev This is 6 months (technically 180 days) in blocks.
     */
    uint256 public constant MAX_STAKER_OPT_OUT_WINDOW_BLOCKS = (180 * 24 * 60 * 60) / 12;

    /// @notice Simple permission for functions that are only callable by the StrategyManager contract.
    modifier onlyStrategyManager() {
        require(msg.sender == address(strategyManager), "onlyStrategyManager");
        _;
    }

    // INITIALIZING FUNCTIONS
    constructor(IStrategyManager _strategyManager, ISlasher _slasher) 
        DelegationManagerStorage(_strategyManager, _slasher)
    {
        _disableInitializers();
        ORIGINAL_CHAIN_ID = block.chainid;
    }

    function initialize(address initialOwner, IPauserRegistry _pauserRegistry, uint256 initialPausedStatus)
        external
        initializer
    {
        _initializePauser(_pauserRegistry, initialPausedStatus);
        _DOMAIN_SEPARATOR = _calculateDomainSeparator();
        _transferOwnership(initialOwner);
    }

    // EXTERNAL FUNCTIONS
    /**
     * @notice Registers the `msg.sender` as an operator in EigenLayer, that stakers can choose to delegate to.
     * @param registeringOperatorDetails is the `OperatorDetails` for the operator.
     * @dev Note that once an operator is registered, they cannot 'deregister' as an operator, and they will forever be considered "delegated to themself".
     * @dev This function will revert if the caller attempts to set their `earningsReceiver` to address(0).
     */
    function registerAsOperator(OperatorDetails calldata registeringOperatorDetails) external {
        require(
            _operatorDetails[msg.sender].earningsReceiver == address(0),
            "DelegationManager.registerAsOperator: operator has already registered"
        );
        _setOperatorDetails(msg.sender, registeringOperatorDetails);
        SignatureWithExpiry memory emptySignatureAndExpiry;
        // delegate from the operator to themselves
        _delegate(msg.sender, msg.sender, emptySignatureAndExpiry);
        emit OperatorRegistered(msg.sender, registeringOperatorDetails);
    }

    /**
     * @notice Updates the `msg.sender`'s stored `OperatorDetails`.
     * @param newOperatorDetails is the updated `OperatorDetails` for the operator, to replace their current OperatorDetails`.
     * @dev The `msg.sender` must have previously registered as an operator in EigenLayer via calling the `registerAsOperator` function.
     * @dev This function will revert if the caller attempts to set their `earningsReceiver` to address(0).
     */
    function modifyOperatorDetails(OperatorDetails calldata newOperatorDetails) external {
        _setOperatorDetails(msg.sender, newOperatorDetails);
    }

    /**
     * @notice Called by a staker to delegate its assets to the @param operator.
     * @param operator is the operator to whom the staker (`msg.sender`) is delegating its assets for use in serving applications built on EigenLayer.
     * @param approverSignatureAndExpiry is a parameter that will be used for verifying that the operator approves of this delegation action in the event that:
     * 1) the operator's `delegationApprover` address is set to a non-zero value.
     * AND
     * 2) neither the operator nor their `delegationApprover` is the `msg.sender`, since in the event that the operator or their delegationApprover
     * is the `msg.sender`, then approval is assumed.
     */
    function delegateTo(address operator, SignatureWithExpiry memory approverSignatureAndExpiry) external {
        // go through the internal delegation flow, checking the `approverSignatureAndExpiry` if applicable
        _delegate(msg.sender, operator, approverSignatureAndExpiry);
    }

    /**
     * @notice Delegates from @param staker to @param operator.
     * @notice This function will revert if the current `block.timestamp` is equal to or exceeds @param expiry
     * @dev The @param stakerSignature is used as follows:
     * 1) If `staker` is an EOA, then `stakerSignature` is verified to be a valid ECDSA stakerSignature from `staker`, indicating their intention for this action.
     * 2) If `staker` is a contract, then `stakerSignature` will be checked according to EIP-1271.
     * @param approverSignatureAndExpiry is a parameter that will be used for verifying that the operator approves of this delegation action in the event that:
     * 1) the operator's `delegationApprover` address is set to a non-zero value.
     * AND
     * 2) neither the operator nor their `delegationApprover` is the `msg.sender`, since in the event that the operator or their delegationApprover
     * is the `msg.sender`, then approval is assumed.
     */
    function delegateToBySignature(
        address staker,
        address operator,
        SignatureWithExpiry memory stakerSignatureAndExpiry,
        SignatureWithExpiry memory approverSignatureAndExpiry
    ) external {
        // check the signature expiry
        require(stakerSignatureAndExpiry.expiry >= block.timestamp, "DelegationManager.delegateToBySignature: staker signature expired");
        // calculate the struct hash, then increment `staker`'s nonce
        uint256 currentStakerNonce = stakerNonce[staker];
        bytes32 stakerStructHash = keccak256(abi.encode(STAKER_DELEGATION_TYPEHASH, staker, operator, currentStakerNonce, stakerSignatureAndExpiry.expiry));
        unchecked {
            stakerNonce[staker] = currentStakerNonce + 1;
        }

        // calculate the digest hash
        bytes32 stakerDigestHash = keccak256(abi.encodePacked("\x19\x01", domainSeparator(), stakerStructHash));

        // actually check that the signature is valid
        EIP1271SignatureUtils.checkSignature_EIP1271(staker, stakerDigestHash, stakerSignatureAndExpiry.signature);

        // go through the internal delegation flow, checking the `approverSignatureAndExpiry` if applicable
        _delegate(staker, operator, approverSignatureAndExpiry);
    }

    /**
     * @notice Undelegates `staker` from the operator who they are delegated to.
     * @notice Callable only by the StrategyManager
     * @dev Should only ever be called in the event that the `staker` has no active deposits in EigenLayer.
     * @dev Reverts if the `staker` is also an operator, since operators are not allowed to undelegate from themselves
     */
    function undelegate(address staker) external onlyStrategyManager {
        require(!isOperator(staker), "DelegationManager.undelegate: operators cannot undelegate from themselves");
        emit StakerUndelegated(staker, delegatedTo[staker]);
        delegatedTo[staker] = address(0);
    }

    // TODO: decide if on the right  auth for this. Perhaps could be another address for the operator to specify
    /**
     * @notice Called by the operator or the operator's `delegationApprover` address, in order to forcibly undelegate a staker who is currently delegated to the operator.
     * @param operator The operator who the @param staker is currently delegated to.
     * @dev This function will revert if either:
     * A) The `msg.sender` does not match `operatorDetails(operator).delegationApprover`.
     * OR
     * B) The `staker` is not currently delegated to the `operator`.
     * @dev This function will also revert if the `staker` is the `operator`; operators are considered *permanently* delegated to themselves.
     * @return The root of the newly queued withdrawal.
     * @dev Note that it is assumed that a staker places some trust in an operator, in paricular for the operator to not get slashed; a malicious operator can use this function
     * to inconvenience a staker who is delegated to them, but the expectation is that the inconvenience is minor compared to the operator getting purposefully slashed.
     */
    function forceUndelegation(address staker, address operator) external returns (bytes32) {
        require(delegatedTo[staker] == operator, "DelegationManager.forceUndelegation: staker is not delegated to operator");
        require(msg.sender == operator || msg.sender == _operatorDetails[operator].delegationApprover,
            "DelegationManager.forceUndelegation: caller must be operator or their delegationApprover");
        return strategyManager.forceUndelegation(staker);
    }

    /**
     * @notice *If the staker is actively delegated*, then increases the `staker`'s delegated shares in `strategy` by `shares`. Otherwise does nothing.
     * Called by the StrategyManager whenever new shares are added to a user's share balance.
     * @dev Callable only by the StrategyManager.
     */
    function increaseDelegatedShares(address staker, IStrategy strategy, uint256 shares)
        external
        onlyStrategyManager
    {
        //if the staker is delegated to an operator
        if (isDelegated(staker)) {
            address operator = delegatedTo[staker];

            // add strategy shares to delegate's shares
            operatorShares[operator][strategy] += shares;
        }
    }

    /**
     * @notice *If the staker is actively delegated*, then decreases the `staker`'s delegated shares in each entry of `strategies` by its respective `shares[i]`. Otherwise does nothing.
     * Called by the StrategyManager whenever shares are decremented from a user's share balance, for example when a new withdrawal is queued.
     * @dev Callable only by the StrategyManager.
     */
    function decreaseDelegatedShares(address staker, IStrategy[] calldata strategies, uint256[] calldata shares)
        external
        onlyStrategyManager
    {
        if (isDelegated(staker)) {
            address operator = delegatedTo[staker];

            // subtract strategy shares from delegate's shares
            uint256 stratsLength = strategies.length;
            for (uint256 i = 0; i < stratsLength;) {
                operatorShares[operator][strategies[i]] -= shares[i];
                unchecked {
                    ++i;
                }
            }
        }
    }

    // INTERNAL FUNCTIONS
    /**
     * @notice Internal function that sets the @param operator 's parameters in the `_operatorDetails` mapping to @param newOperatorDetails
     * @dev This function will revert if the operator attempts to set their `earningsReceiver` to address(0).
     */
    function _setOperatorDetails(address operator, OperatorDetails calldata newOperatorDetails) internal {
        require(
            newOperatorDetails.earningsReceiver != address(0),
            "DelegationManager._setOperatorDetails: cannot set `earningsReceiver` to zero address"
        );
        require(newOperatorDetails.stakerOptOutWindowBlocks <= MAX_STAKER_OPT_OUT_WINDOW_BLOCKS,
            "DelegationManager._setOperatorDetails: stakerOptOutWindowBlocks cannot be > MAX_STAKER_OPT_OUT_WINDOW_BLOCKS");
        require(newOperatorDetails.stakerOptOutWindowBlocks >= _operatorDetails[operator].stakerOptOutWindowBlocks,
            "DelegationManager._setOperatorDetails: stakerOptOutWindowBlocks cannot be decreased");
        _operatorDetails[operator] = newOperatorDetails;
        emit OperatorDetailsModified(msg.sender, newOperatorDetails);
    }

    /**
     * @notice Internal function implementing the delegation *from* `staker` *to* `operator`.
     * @param staker The address to delegate *from* -- this address is delegating control of its own assets.
     * @param operator The address to delegate *to* -- this address is being given power to place the `staker`'s assets at risk on services
     * @dev Ensures that:
     * 1) the `staker` is not already delegated to an operator
     * 2) the `operator` has indeed registered as an operator in EigenLayer
     * 3) the `operator` is not actively frozen
     * 4) if applicable, that the approver signature is valid and non-expired
     */ 
    function _delegate(address staker, address operator, SignatureWithExpiry memory approverSignatureAndExpiry) internal onlyWhenNotPaused(PAUSED_NEW_DELEGATION) {
        require(isNotDelegated(staker), "DelegationManager._delegate: staker has existing delegation");
        require(isOperator(operator), "DelegationManager._delegate: operator is not registered in EigenLayer");
        require(!slasher.isFrozen(operator), "DelegationManager._delegate: cannot delegate to a frozen operator");

        // fetch the operator's `delegationApprover` address and store it in memory in case we need to use it multiple times
        address _delegationApprover = _operatorDetails[operator].delegationApprover;
        /**
         * Check the `_delegationApprover`'s signature, if applicable.
         * If the `_delegationApprover` is the zero address, then the operator allows all stakers to delegate to them and this verification is skipped.
         * If the `_delegationApprover` or the `operator` themselves is the caller, then approval is assumed and signature verification is skipped as well.
         */
        if (_delegationApprover != address(0) && msg.sender != _delegationApprover && msg.sender != operator) {
            // check the signature expiry
            require(approverSignatureAndExpiry.expiry >= block.timestamp, "DelegationManager._delegate: approver signature expired");

            // calculate the struct hash, then increment `delegationApprover`'s nonce
            uint256 currentApproverNonce = delegationApproverNonce[_delegationApprover];
            bytes32 approverStructHash = keccak256(abi.encode(DELEGATION_APPROVAL_TYPEHASH, _delegationApprover, operator, currentApproverNonce, approverSignatureAndExpiry.expiry));
            unchecked {
                delegationApproverNonce[_delegationApprover] = currentApproverNonce + 1;
            }

            // calculate the digest hash
            bytes32 approverDigestHash = keccak256(abi.encodePacked("\x19\x01", domainSeparator(), approverStructHash));

            // actually check that the signature is valid
            EIP1271SignatureUtils.checkSignature_EIP1271(_delegationApprover, approverDigestHash, approverSignatureAndExpiry.signature);
        }

        // retrieve `staker`'s list of strategies and the staker's shares in each strategy from the StrategyManager
        (IStrategy[] memory strategies, uint256[] memory shares) = strategyManager.getDeposits(staker);

        // add strategy shares to delegated `operator`'s shares
        uint256 stratsLength = strategies.length;
        for (uint256 i = 0; i < stratsLength;) {
            // update the share amounts for each of the `operator`'s strategies
            operatorShares[operator][strategies[i]] += shares[i];
            unchecked {
                ++i;
            }
        }

        // record the delegation relation between the staker and operator, and emit an event
        delegatedTo[staker] = operator;
        emit StakerDelegated(staker, operator);
    }

    // VIEW FUNCTIONS
    /**
     * @notice Getter function for the current EIP-712 domain separator for this contract.
     * @dev The domain separator will change in the event of a fork that changes the ChainID.
     */
    function domainSeparator() public view returns (bytes32) {
        if (block.chainid == ORIGINAL_CHAIN_ID) {
            return _DOMAIN_SEPARATOR;
        }
        else {
            return _calculateDomainSeparator();
        }
    }

    /// @notice Returns 'true' if `staker` *is* actively delegated, and 'false' otherwise.
    function isDelegated(address staker) public view returns (bool) {
        return (delegatedTo[staker] != address(0));
    }

    /// @notice Returns 'true' if `staker` is *not* actively delegated, and 'false' otherwise.
    function isNotDelegated(address staker) public view returns (bool) {
        return (delegatedTo[staker] == address(0));
    }

    /// @notice Returns if an operator can be delegated to, i.e. the `operator` has previously called `registerAsOperator`.
    function isOperator(address operator) public view returns (bool) {
        return (_operatorDetails[operator].earningsReceiver != address(0));
    }

    /**
     * @notice returns the OperatorDetails of the `operator`.
     * @notice Mapping: operator => OperatorDetails struct
     */
    function operatorDetails(address operator) external view returns (OperatorDetails memory) {
        return _operatorDetails[operator];
    }

    // @notice Getter function for `_operatorDetails[operator].earningsReceiver`
    function earningsReceiver(address operator) external view returns (address) {
        return _operatorDetails[operator].earningsReceiver;
    }

    // @notice Getter function for `_operatorDetails[operator].delegationApprover`
    function delegationApprover(address operator) external view returns (address) {
        return _operatorDetails[operator].delegationApprover;
    }

    // @notice Getter function for `_operatorDetails[operator].stakerOptOutWindowBlocks`
    function stakerOptOutWindowBlocks(address operator) external view returns (uint256) {
        return _operatorDetails[operator].stakerOptOutWindowBlocks;
    }

    function _calculateDomainSeparator() internal view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256(bytes("EigenLayer")), block.chainid, address(this)));
    }
}
