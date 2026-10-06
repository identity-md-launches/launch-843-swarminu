// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SwarmInu} from "src/SwarmInu.sol";
import {MockProjectFactory} from "./utils/FactoryMocks.sol";

/// @dev Closed actor set: three wallets, factory, manager, two candidate distributors, fee wallet.
/// Ghost balances come from requested amounts, never from the token's fee/exemption helpers.
/// Factory record changes exercise the external dependency; they are not a permission granted to holders.
contract SwarmInuHandler is Test {
    uint256 private constant SUPPLY = 1_000_000_000e18;
    uint64 private constant LAUNCH = 7;
    SwarmInu public immutable token;
    MockProjectFactory public immutable factory;
    address[8] public actors;
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;
    address public currentDistributor;
    uint256 public successfulTransfers;
    uint256 public rejectedTransfers;
    uint256 public assessedFees;

    constructor() {
        factory = new MockProjectFactory();
        actors = [
            address(0xA11CE),
            address(0xB0B),
            address(0xCA201),
            address(factory),
            address(0x9001),
            address(0xD157),
            address(0xD158),
            address(0x66522f25035C3FAFd2c6D950a506FDa457E06344)
        ];
        token = factory.deployToken(actors[4], LAUNCH);
        expectedBalance[address(factory)] = SUPPLY;
        currentDistributor = actors[5];
        factory.setDistributor(LAUNCH, currentDistributor);
        // Fund every role through real transfers, retaining most of the supply at the factory.
        for (uint256 i; i < actors.length; ++i) {
            if (i == 3) continue;
            factory.move(token, actors[i], SUPPLY / 20);
            _recordTransfer(address(factory), address(factory), actors[i], SUPPLY / 20);
        }
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 amount = _amount(amountSeed, expectedBalance[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        _recordTransfer(from, from, to, amount);
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed) external {
        uint256 allowance = amountSeed % 4 == 0 ? type(uint256).max : bound(amountSeed, 0, SUPPLY);
        _approve(_actor(ownerSeed), _actor(spenderSeed), allowance);
    }

    function spendAllowance(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 limit = expectedBalance[owner];
        uint256 allowance = expectedAllowance[owner][spender];
        if (allowance < limit) limit = allowance;
        _spend(owner, spender, _actor(toSeed), _amount(amountSeed, limit));
    }

    function approveAndSpend(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed, bool infinite)
        external
    {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 amount = _amount(amountSeed, expectedBalance[owner]);
        _approve(owner, spender, infinite ? type(uint256).max : amount);
        _spend(owner, spender, _actor(toSeed), amount);
    }

    function rejectInsufficientBalance(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, bool infinite) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 balance = expectedBalance[owner];
        uint256 amount = balance + 1;
        _approve(owner, spender, infinite ? type(uint256).max : amount);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, balance, amount));
        vm.prank(spender);
        token.transferFrom(owner, to, amount);
        // No ghost debit: both allowance spending and any fee leg must have rolled back.
        ++rejectedTransfers;
    }

    function rejectInsufficientAllowance(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed)
        external
    {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 amount = bound(amountSeed, 1, SUPPLY);
        _approve(owner, spender, amount - 1);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, amount - 1, amount)
        );
        vm.prank(spender);
        token.transferFrom(owner, to, amount);
        ++rejectedTransfers;
    }

    function rejectZeroReceiver(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 amount = _amount(amountSeed, expectedBalance[owner]);
        _approve(owner, spender, amount);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(owner, address(0), amount);
        ++rejectedTransfers;
    }

    function rotateDistributor(uint256 choice) external {
        uint256 selected = choice % 3;
        currentDistributor = selected == 0 ? address(0) : actors[4 + selected];
        factory.setDistributor(LAUNCH, currentDistributor);
        // An unrelated launch must never confer an exemption for this token.
        factory.setDistributor(LAUNCH + 1, actors[2]);
    }

    function _approve(address owner, address spender, uint256 amount) private {
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        expectedAllowance[owner][spender] = amount;
    }

    function _spend(address owner, address spender, address to, uint256 amount) private {
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount));
        if (expectedAllowance[owner][spender] != type(uint256).max) {
            expectedAllowance[owner][spender] -= amount;
        }
        _recordTransfer(spender, owner, to, amount);
    }

    function _recordTransfer(address operator, address from, address to, uint256 amount) private {
        bool exact = operator == actors[3] || from == actors[3] || to == actors[3] || to == actors[4]
            || from == actors[7] || to == actors[7]
            || (currentDistributor != address(0) && (from == currentDistributor || to == currentDistributor));
        // One fee unit per fifty minor units; independent of the production multiply/divide expression.
        uint256 fee = exact ? 0 : amount / 50;
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount - fee;
        expectedBalance[actors[7]] += fee;
        assessedFees += fee;
        ++successfulTransfers;
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % actors.length];
    }

    function _amount(uint256 seed, uint256 limit) private pure returns (uint256) {
        uint256 edge = seed % 8;
        if (edge == 0) return 0;
        if (edge == 1) return limit;
        uint256 amount = edge == 2 ? 1 : edge == 3 ? 49 : edge == 4 ? 50 : edge == 5 ? 51 : seed;
        return amount > limit ? bound(amount, 0, limit) : amount;
    }
}

contract SwarmInuInvariantTest is Test {
    SwarmInuHandler internal handler;
    SwarmInu internal token;

    function setUp() public {
        handler = new SwarmInuHandler();
        token = handler.token();
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.spendAllowance.selector;
        selectors[3] = handler.approveAndSpend.selector;
        selectors[4] = handler.rejectInsufficientBalance.selector;
        selectors[5] = handler.rejectInsufficientAllowance.selector;
        selectors[6] = handler.rejectZeroReceiver.selector;
        selectors[7] = handler.rotateDistributor.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 128
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_supplyBalancesAndAllowancesAgreeWithModel() public view {
        uint256 sum;
        for (uint256 i; i < 8; ++i) {
            address actor = handler.actors(i);
            uint256 balance = token.balanceOf(actor);
            sum += balance;
            assertEq(balance, handler.expectedBalance(actor), "balance disagrees with independent accounting");
            for (uint256 j; j < 8; ++j) {
                address spender = handler.actors(j);
                assertEq(
                    token.allowance(actor, spender),
                    handler.expectedAllowance(actor, spender),
                    "approval, gross debit, or revert rollback is wrong"
                );
            }
        }
        assertEq(sum, 1_000_000_000e18, "tokens lost or created across the closed actor set");
        assertEq(token.totalSupply(), sum, "supply differs from outstanding balances");
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.distributor(), handler.currentDistributor());
    }

    /// @dev A deterministic sequence exercises every handler and checks each intermediate state.
    function test_handlerExercisesTaxedExemptAndRejectedPaths() public {
        handler.transfer(0, 1, 100e18 + 6);
        invariant_supplyBalancesAndAllowancesAgreeWithModel();
        handler.approve(0, 2, 100e18);
        invariant_supplyBalancesAndAllowancesAgreeWithModel();
        handler.spendAllowance(0, 2, 1, 1); // Spend the full available allowance/balance.
        invariant_supplyBalancesAndAllowancesAgreeWithModel();
        handler.approveAndSpend(1, 3, 2, 1, false); // Factory still consumes gross allowance.
        invariant_supplyBalancesAndAllowancesAgreeWithModel();
        handler.approveAndSpend(2, 0, 2, 4, true); // Delegated self-transfer of 50 wei with infinite approval.
        invariant_supplyBalancesAndAllowancesAgreeWithModel();
        handler.rejectInsufficientBalance(0, 3, 1, false);
        invariant_supplyBalancesAndAllowancesAgreeWithModel();
        handler.rejectInsufficientAllowance(0, 7, 1, 100e18);
        invariant_supplyBalancesAndAllowancesAgreeWithModel();
        handler.rejectZeroReceiver(0, 2, 50);
        invariant_supplyBalancesAndAllowancesAgreeWithModel();
        handler.rotateDistributor(2);
        handler.transfer(5, 0, 1); // Former distributor is now taxable.
        handler.transfer(6, 1, 1); // New distributor pays claims in full.
        invariant_supplyBalancesAndAllowancesAgreeWithModel();
        assertGt(handler.assessedFees(), 0);
        assertEq(handler.rejectedTransfers(), 3);
        assertGt(handler.successfulTransfers(), 7);
    }
}
