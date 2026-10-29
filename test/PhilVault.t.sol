// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {PhilVault} from "../src/PhilVault.sol";

contract Reenterer {
    PhilVault public vault;
    bool public viaReward;

    function set(PhilVault v, bool reward) external {
        vault = v;
        viaReward = reward;
    }

    receive() external payable {
        if (address(vault) == address(0)) return;
        if (viaReward) vault.rewardJab(keccak256("again"), address(this), 1, keccak256("x")); // must hit the guard
        else vault.distribute();
    }
}

contract PhilVaultTest is Test {
    PhilVault vault;
    address guardian = makeAddr("phil-guardian");
    address treasury = makeAddr("phil-treasury");
    address agent = makeAddr("phil-ai-agent");
    address memer = makeAddr("phil-memer");
    address anyone = makeAddr("phil-anyone");

    bytes32 constant JAB = keccak256("jab-0001");
    bytes32 constant POST = keccak256("https://x.com/memer/status/1");

    function setUp() public {
        vm.warp(1_800_000_000);
        vault = new PhilVault(guardian, treasury, agent);
    }

    function _fund(uint256 amount) internal {
        vm.deal(address(this), amount);
        (bool ok,) = address(vault).call{value: amount}("");
        assertTrue(ok);
    }

    function _reward(bytes32 id, address to, uint256 amount) internal {
        vm.prank(agent);
        vault.rewardJab(id, to, amount, POST);
    }

    function test_split80_20() public {
        _fund(1 ether);
        vault.distribute();
        assertEq(treasury.balance, 0.8 ether, "project treasury");
        assertEq(vault.jabPool(), 0.2 ether, "jab pool kept");
        assertEq(address(vault).balance, 0.2 ether);
        assertEq(vault.pending(), 0);
        assertEq(vault.totalDistributed(), 1 ether);
    }

    function test_anyoneCanDistribute_repeatedSafely() public {
        _fund(1 ether);
        vm.prank(anyone);
        vault.distribute();
        vm.prank(anyone);
        vault.distribute();
        _fund(1 ether);
        vault.distribute();
        assertEq(vault.jabPool(), 0.4 ether);
        assertEq(treasury.balance, 1.6 ether);
    }

    function test_agentRewardsAMeme() public {
        _fund(10 ether);
        vault.distribute(); // 2 ETH pool
        _reward(JAB, memer, 0.2 ether); // exactly 10%
        assertEq(memer.balance, 0.2 ether);
        assertEq(vault.jabPool(), 1.8 ether);
        assertEq(vault.totalRewardsPaid(), 0.2 ether);
        assertEq(vault.rewardCount(), 1);
        assertTrue(vault.rewarded(JAB));
        vm.prank(agent);
        vm.expectRevert(PhilVault.AlreadyRewarded.selector);
        vault.rewardJab(JAB, memer, 1, POST);
    }

    function test_onlyAgent_andRewardRules() public {
        _fund(10 ether);
        vault.distribute();
        vm.prank(anyone);
        vm.expectRevert(PhilVault.NotAgent.selector);
        vault.rewardJab(JAB, memer, 1, POST);
        vm.prank(guardian);
        vm.expectRevert(PhilVault.NotAgent.selector);
        vault.rewardJab(JAB, memer, 1, POST);
        vm.startPrank(agent);
        vm.expectRevert(PhilVault.BadJab.selector);
        vault.rewardJab(bytes32(0), memer, 1, POST);
        vm.expectRevert(PhilVault.BadJab.selector);
        vault.rewardJab(JAB, memer, 1, bytes32(0));
        vm.expectRevert(PhilVault.BadJab.selector);
        vault.rewardJab(JAB, memer, 0, POST);
        vm.expectRevert(PhilVault.ZeroAddress.selector);
        vault.rewardJab(JAB, address(0), 1, POST);
        vm.expectRevert(PhilVault.RewardTooLarge.selector);
        vault.rewardJab(JAB, memer, 0.2 ether + 1, POST);
        vm.stopPrank();
    }

    function test_neverPaysTeamWallets() public {
        _fund(10 ether);
        vault.distribute();
        address[4] memory banned = [treasury, guardian, agent, address(vault)];
        for (uint256 i; i < banned.length; ++i) {
            vm.prank(agent);
            vm.expectRevert(PhilVault.RecipientNotAllowed.selector);
            vault.rewardJab(keccak256(abi.encode(i)), banned[i], 1, POST);
        }
        address next = makeAddr("phil-next-treasury");
        vm.prank(guardian);
        vault.proposeTreasury(next); // a pending treasury is excluded too
        vm.prank(agent);
        vm.expectRevert(PhilVault.RecipientNotAllowed.selector);
        vault.rewardJab(JAB, next, 1, POST);
    }

    function test_dayBudget25Percent_resetsNextDay() public {
        _fund(10 ether);
        vault.distribute(); // pool 2 ETH, day budget 0.5 ETH
        _reward(keccak256("a"), memer, 0.2 ether);
        _reward(keccak256("b"), memer, 0.18 ether);
        _reward(keccak256("c"), memer, 0.12 ether); // 0.5 ETH spent
        vm.prank(agent);
        vm.expectRevert(PhilVault.DayBudgetExceeded.selector);
        vault.rewardJab(keccak256("d"), memer, 1, POST);
        vm.warp(block.timestamp + 1 days);
        _reward(keccak256("d"), memer, 0.15 ether); // new day, budget 25% of 1.5 ETH
        assertEq(vault.dayBudget(), 0.375 ether);
        assertEq(memer.balance, 0.65 ether);
    }

    function test_guardianPausesAgentAtOnce() public {
        _fund(10 ether);
        vault.distribute();
        vm.prank(anyone);
        vm.expectRevert(PhilVault.NotGuardian.selector);
        vault.setAgentPaused(true);
        vm.prank(guardian);
        vault.setAgentPaused(true);
        vm.prank(agent);
        vm.expectRevert(PhilVault.IsPaused.selector);
        vault.rewardJab(JAB, memer, 1, POST);
        vm.prank(guardian);
        vault.setAgentPaused(false);
        _reward(JAB, memer, 1);
        assertEq(memer.balance, 1);
    }

    function test_poolCannotLeaveAnyOtherWay() public {
        _fund(2 ether);
        vault.distribute();
        uint256 pool = vault.jabPool();
        vault.distribute();
        assertEq(address(vault).balance, pool);
        assertEq(vault.pending(), 0);
    }

    function test_treasuryTimelock_oldFeesToOldTreasury() public {
        address next = makeAddr("phil-new-treasury");
        vm.prank(guardian);
        vault.proposeTreasury(next);
        _fund(1 ether);
        vm.prank(guardian);
        vm.expectRevert(PhilVault.TooEarly.selector);
        vault.executeTreasury();
        vm.warp(block.timestamp + 48 hours);
        vm.prank(guardian);
        vault.executeTreasury();
        assertEq(treasury.balance, 0.8 ether, "old treasury got the old fees");
        assertEq(vault.treasury(), next);
    }

    function test_agentAndGuardianTimelocked() public {
        address nextAgent = makeAddr("phil-agent-2");
        address dao = makeAddr("phil-dao");
        vm.startPrank(guardian);
        vm.expectRevert(PhilVault.ZeroAddress.selector);
        vault.proposeAgent(address(0));
        vault.proposeAgent(nextAgent);
        vault.proposeGuardian(dao);
        vm.expectRevert(PhilVault.TooEarly.selector);
        vault.executeAgent();
        vm.expectRevert(PhilVault.TooEarly.selector);
        vault.executeGuardian();
        vm.warp(block.timestamp + 48 hours);
        vault.executeAgent();
        vault.cancelProposal(2);
        vm.expectRevert(PhilVault.NothingPending.selector);
        vault.executeGuardian();
        vm.stopPrank();
        assertEq(vault.agent(), nextAgent);
        assertEq(vault.guardian(), guardian);
        _fund(10 ether);
        vault.distribute();
        vm.prank(agent); // the old agent lost its power
        vm.expectRevert(PhilVault.NotAgent.selector);
        vault.rewardJab(JAB, memer, 1, POST);
    }

    function test_reentrantTreasuryCannotDoubleDistribute() public {
        Reenterer r = new Reenterer();
        PhilVault v = new PhilVault(guardian, address(r), agent);
        r.set(v, false);
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(v).call{value: 1 ether}("");
        assertTrue(ok);
        vm.expectRevert(PhilVault.TransferFailed.selector);
        v.distribute();
    }

    function test_reentrantRecipientCannotDoubleCollect() public {
        Reenterer r = new Reenterer();
        PhilVault v = new PhilVault(guardian, treasury, address(r)); // the reenterer is also the agent
        vm.deal(address(this), 10 ether);
        (bool ok,) = address(v).call{value: 10 ether}("");
        assertTrue(ok);
        v.distribute();
        r.set(v, true);
        vm.prank(address(r));
        vm.expectRevert(PhilVault.RecipientNotAllowed.selector); // the agent can never pay itself
        v.rewardJab(JAB, address(r), 1, POST);
        Reenterer grantee = new Reenterer();
        grantee.set(v, true);
        vm.prank(address(r));
        vm.expectRevert(PhilVault.TransferFailed.selector); // a recipient re-entering hits the guard
        v.rewardJab(JAB, address(grantee), 1, POST);
    }

    function test_zeroAddressesRejected() public {
        vm.expectRevert(PhilVault.ZeroAddress.selector);
        new PhilVault(address(0), treasury, agent);
        vm.expectRevert(PhilVault.ZeroAddress.selector);
        new PhilVault(guardian, address(0), agent);
        vm.expectRevert(PhilVault.ZeroAddress.selector);
        new PhilVault(guardian, treasury, address(0));
    }

    function testFuzz_splitAlwaysAddsUp(uint96 amount) public {
        vm.assume(amount > 0);
        _fund(amount);
        vault.distribute();
        assertEq(treasury.balance + vault.jabPool(), amount);
        assertEq(address(vault).balance, vault.jabPool());
    }

    function testFuzz_rewardsNeverBreakCaps(uint96 funded, uint128 a, uint128 b) public {
        vm.assume(funded > 1000);
        _fund(funded);
        vault.distribute();
        uint256 pool0 = vault.jabPool();
        uint256 x = bound(a, 1, pool0 / 10);
        _reward(keccak256("x"), memer, x);
        uint256 y = bound(b, 1, type(uint96).max);
        uint256 poolNow = vault.jabPool(); // read before arming the prank
        vm.prank(agent);
        if (y > poolNow / 10) vm.expectRevert(PhilVault.RewardTooLarge.selector);
        else if (x + y > pool0 / 4) vm.expectRevert(PhilVault.DayBudgetExceeded.selector);
        vault.rewardJab(keccak256("y"), memer, y, POST);
        assertLe(memer.balance, pool0 / 4);
    }
}
