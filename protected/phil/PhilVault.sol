// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title ELON PHIL XXXL Vault and Jab Pool
/// @notice The immutable creator-fee recipient of the $ELONPHILXXXL pool, which runs Programmable's sealed
///         launch-protection hook. Anyone may call the hook fee vault's claimCreator() to push accrued creator fees
///         (ETH) here, and anyone may call distribute().
///
///         Every distribution splits the ETH waiting here in fixed shares:
///           80% Project treasury wallet (team, development, operations and marketing; free to use)
///           20% Jab Pool, kept here; it can only leave as a meme reward paid by Phil AI
///
///         Phil AI is an off-chain agent whose wallet (the agent) can pay a reward for a community meme or post
///         (a "jab"): once per jab id, with the hash of the jab, at most MAX_REWARD_BPS of the pool per reward and at
///         most MAX_DAY_BPS of the pool per day, and never to the treasury, the guardian, the agent or this vault.
///
///         The guardian can pause and unpause the agent at once (pausing moves no ETH). It can change the treasury
///         wallet, the agent or itself only through a 48-hour public timelock. There is no other way to move ETH out
///         of this contract.
contract PhilVault {
    uint16 public constant BPS = 10_000;
    uint16 public constant SHARE_TREASURY_BPS = 8_000;
    uint16 public constant SHARE_JAB_BPS = 2_000;
    /// @notice A single reward is at most 10% of the Jab Pool.
    uint16 public constant MAX_REWARD_BPS = 1_000;
    /// @notice All rewards in one UTC day are at most 25% of the Jab Pool as it stood at that day's first reward.
    uint16 public constant MAX_DAY_BPS = 2_500;
    uint32 public constant TIMELOCK = 48 hours;

    address public guardian;
    address public treasury;
    address public agent;
    bool public agentPaused;

    uint256 public jabPool;
    uint256 public totalDistributed;
    uint256 public totalRewardsPaid;
    uint256 public rewardCount;
    mapping(bytes32 jabId => bool) public rewarded;

    uint64 public rewardDay;
    uint256 public dayBudget;
    uint256 public daySpent;

    // ---- timelocked changes
    address public pendingTreasury;
    uint64 public treasuryReadyAt;
    address public pendingAgent;
    uint64 public agentReadyAt;
    address public pendingGuardian;
    uint64 public guardianReadyAt;

    bool private _locked;

    event Received(address indexed from, uint256 amount);
    event Distributed(uint256 toJabPool, uint256 toTreasury);
    event JabRewarded(bytes32 indexed jabId, address indexed to, uint256 amount, bytes32 jabHash);
    event AgentPaused(bool paused);
    event TreasuryProposed(address next, uint64 readyAt);
    event TreasuryChanged(address previous, address next);
    event AgentProposed(address next, uint64 readyAt);
    event AgentChanged(address previous, address next);
    event GuardianProposed(address next, uint64 readyAt);
    event GuardianChanged(address previous, address next);
    event ProposalCancelled(uint8 kind);

    error ZeroAddress();
    error NotGuardian();
    error NotAgent();
    error IsPaused();
    error BadJab();
    error AlreadyRewarded();
    error RecipientNotAllowed();
    error RewardTooLarge();
    error DayBudgetExceeded();
    error TooEarly();
    error NothingPending();
    error TransferFailed();
    error Reentrant();

    modifier nonReentrant() {
        if (_locked) revert Reentrant();
        _locked = true;
        _;
        _locked = false;
    }

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert NotGuardian();
        _;
    }

    constructor(address guardian_, address treasury_, address agent_) {
        if (guardian_ == address(0) || treasury_ == address(0) || agent_ == address(0)) revert ZeroAddress();
        guardian = guardian_;
        treasury = treasury_;
        agent = agent_;
    }

    receive() external payable {
        emit Received(msg.sender, msg.value);
    }

    /// @notice ETH waiting to be split (everything except the Jab Pool).
    function pending() public view returns (uint256) {
        return address(this).balance - jabPool;
    }

    // ================================================================== permissionless
    function distribute() external nonReentrant {
        _distribute();
    }

    // ================================================================== Phil AI
    /// @notice Pay a meme reward from the Jab Pool. The jab hash commits to the public post being rewarded.
    function rewardJab(bytes32 jabId, address to, uint256 amount, bytes32 jabHash) external nonReentrant {
        if (msg.sender != agent) revert NotAgent();
        if (agentPaused) revert IsPaused();
        if (jabId == bytes32(0) || jabHash == bytes32(0) || amount == 0) revert BadJab();
        if (rewarded[jabId]) revert AlreadyRewarded();
        if (to == address(0)) revert ZeroAddress();
        if (!_allowedRecipient(to)) revert RecipientNotAllowed();
        if (amount > jabPool * MAX_REWARD_BPS / BPS) revert RewardTooLarge();
        uint64 today = uint64(block.timestamp / 1 days) + 1; // +1 so day numbering never equals the unset value 0
        if (today != rewardDay) {
            rewardDay = today;
            dayBudget = jabPool * MAX_DAY_BPS / BPS;
            daySpent = 0;
        }
        if (daySpent + amount > dayBudget) revert DayBudgetExceeded();
        rewarded[jabId] = true;
        daySpent += amount;
        jabPool -= amount;
        totalRewardsPaid += amount;
        rewardCount += 1;
        _send(to, amount);
        emit JabRewarded(jabId, to, amount, jabHash);
    }

    // ================================================================== guardian
    /// @notice Stop or resume Phil AI's rewards at once. Pausing moves no ETH.
    function setAgentPaused(bool paused) external onlyGuardian {
        agentPaused = paused;
        emit AgentPaused(paused);
    }

    function proposeTreasury(address next) external onlyGuardian {
        if (next == address(0)) revert ZeroAddress();
        pendingTreasury = next;
        treasuryReadyAt = uint64(block.timestamp + TIMELOCK);
        emit TreasuryProposed(next, treasuryReadyAt);
    }

    function executeTreasury() external onlyGuardian nonReentrant {
        if (treasuryReadyAt == 0) revert NothingPending();
        if (block.timestamp < treasuryReadyAt) revert TooEarly();
        _distribute(); // fees earned under the old treasury go to it
        emit TreasuryChanged(treasury, pendingTreasury);
        treasury = pendingTreasury;
        pendingTreasury = address(0);
        treasuryReadyAt = 0;
    }

    function proposeAgent(address next) external onlyGuardian {
        if (next == address(0)) revert ZeroAddress();
        pendingAgent = next;
        agentReadyAt = uint64(block.timestamp + TIMELOCK);
        emit AgentProposed(next, agentReadyAt);
    }

    function executeAgent() external onlyGuardian {
        if (agentReadyAt == 0) revert NothingPending();
        if (block.timestamp < agentReadyAt) revert TooEarly();
        emit AgentChanged(agent, pendingAgent);
        agent = pendingAgent;
        pendingAgent = address(0);
        agentReadyAt = 0;
    }

    /// @notice Hand the guardian role to a new wallet, Safe or DAO, or to address(0) to renounce, after the timelock.
    function proposeGuardian(address next) external onlyGuardian {
        pendingGuardian = next;
        guardianReadyAt = uint64(block.timestamp + TIMELOCK);
        emit GuardianProposed(next, guardianReadyAt);
    }

    function executeGuardian() external onlyGuardian {
        if (guardianReadyAt == 0) revert NothingPending();
        if (block.timestamp < guardianReadyAt) revert TooEarly();
        emit GuardianChanged(guardian, pendingGuardian);
        guardian = pendingGuardian;
        pendingGuardian = address(0);
        guardianReadyAt = 0;
    }

    /// @param kind 0 treasury, 1 agent, 2 guardian
    function cancelProposal(uint8 kind) external onlyGuardian {
        if (kind == 0) {
            pendingTreasury = address(0);
            treasuryReadyAt = 0;
        } else if (kind == 1) {
            pendingAgent = address(0);
            agentReadyAt = 0;
        } else {
            pendingGuardian = address(0);
            guardianReadyAt = 0;
        }
        emit ProposalCancelled(kind);
    }

    // ================================================================== internals
    function _distribute() internal {
        uint256 amount = pending();
        if (amount == 0) return;
        uint256 toTreasury = amount * SHARE_TREASURY_BPS / BPS;
        uint256 toJab = amount - toTreasury;
        // Book the Jab Pool share before any ETH leaves, so pending() can never count it again.
        jabPool += toJab;
        totalDistributed += amount;
        _send(treasury, toTreasury);
        emit Distributed(toJab, toTreasury);
    }

    function _allowedRecipient(address r) private view returns (bool) {
        return r != treasury && r != guardian && r != agent && r != pendingTreasury && r != pendingGuardian
            && r != pendingAgent && r != address(this);
    }

    function _send(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
