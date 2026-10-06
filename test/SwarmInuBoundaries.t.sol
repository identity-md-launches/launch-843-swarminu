// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SwarmInu} from "src/SwarmInu.sol";
import {MockProjectFactory} from "./utils/FactoryMocks.sol";

contract SwarmInuBoundariesTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000e18;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant SPENDER = address(0xCA201);
    address private constant POOL = address(0x9001);
    address private constant FEE_WALLET = 0x66522f25035C3FAFd2c6D950a506FDa457E06344;
    MockProjectFactory private factory;
    SwarmInu private token;

    function setUp() public {
        factory = new MockProjectFactory();
        token = factory.deployToken(POOL, 7);
        factory.move(token, ALICE, SUPPLY);
    }

    function test_oneWeiMovesWithoutDustLoss() public {
        vm.expectEmit(address(token));
        emit IERC20.Transfer(ALICE, BOB, 1);
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 1));
        _assertBalances(SUPPLY - 1, 1, 0);
    }

    function test_entireSupplyCanBeSpentWithExactGrossAllowance() public {
        _approve(SPENDER, SUPPLY);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(ALICE, BOB, SUPPLY));
        _assertBalances(0, 980_000_000e18, 20_000_000e18);
        assertEq(token.allowance(ALICE, SPENDER), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 0, 1));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 1);
        _assertBalances(0, 980_000_000e18, 20_000_000e18);
    }

    function test_infiniteApprovalSurvivesRepeatedTaxedSpendsAndCanBeRevoked() public {
        _approve(SPENDER, type(uint256).max);
        vm.startPrank(SPENDER);
        assertTrue(token.transferFrom(ALICE, BOB, 100e18));
        assertTrue(token.transferFrom(ALICE, BOB, 100e18));
        vm.stopPrank();
        assertEq(token.allowance(ALICE, SPENDER), type(uint256).max);
        _assertBalances(SUPPLY - 200e18, 196e18, 4e18);

        _approve(SPENDER, 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 0, 100e18));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 100e18);
        _assertBalances(SUPPLY - 200e18, 196e18, 4e18);
        assertEq(token.allowance(ALICE, SPENDER), 0);
    }

    function test_approvalReplacementAndNetOnlyApprovalCannotAuthorizeGrossSpend() public {
        _approve(SPENDER, 100e18);
        _approve(SPENDER, 98e18);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 98e18, 100e18)
        );
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 100e18);
        _assertBalances(SUPPLY, 0, 0);
        assertEq(token.allowance(ALICE, SPENDER), 98e18);
    }

    function test_finiteAllowanceRollsBackWhenBalanceIsInsufficient() public {
        _assertFailedBalanceSpend(SUPPLY + 1, SUPPLY + 1, SPENDER);
    }

    function test_exemptFactoryStillRollsBackAllowanceWhenBalanceIsInsufficient() public {
        _assertFailedBalanceSpend(SUPPLY + 1, SUPPLY + 1, address(factory));
    }

    function test_maximumTransferFromReportsBalanceErrorWithoutTakingAFee() public {
        _assertFailedBalanceSpend(type(uint256).max, type(uint256).max, SPENDER);
    }

    function test_maximumDirectTransferReportsBalanceErrorWithoutArithmeticPanic() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, SUPPLY, type(uint256).max)
        );
        vm.prank(ALICE);
        token.transfer(BOB, type(uint256).max);
        _assertBalances(SUPPLY, 0, 0);
    }

    function test_zeroRecipientRollsBackFiniteAllowanceAndFees() public {
        _approve(SPENDER, 100e18);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, address(0), 100e18);
        _assertBalances(SUPPLY, 0, 0);
        assertEq(token.allowance(ALICE, SPENDER), 100e18);
    }

    function test_zeroTransferFromNeedsNoAllowanceAndEmitsTransfer() public {
        vm.expectEmit(address(token));
        emit IERC20.Transfer(ALICE, BOB, 0);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(ALICE, BOB, 0));
        _assertBalances(SUPPLY, 0, 0);
        assertEq(token.allowance(ALICE, SPENDER), 0);
    }

    function test_zeroAmountCannotBypassInvalidAddresses() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(ALICE);
        token.transfer(address(0), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, address(0), 0);
        // OpenZeppelin validates the allowance owner before reaching the transfer's sender check.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        vm.prank(SPENDER);
        token.transferFrom(address(0), BOB, 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(ALICE);
        token.approve(address(0), 0);
        _assertBalances(SUPPLY, 0, 0);
        assertEq(token.allowance(ALICE, address(0)), 0);
    }

    function test_delegatedSelfTransferConsumesGrossAllowanceAndOnlyLosesFee() public {
        _approve(SPENDER, 100e18);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(ALICE, ALICE, 100e18));
        _assertBalances(SUPPLY - 2e18, 0, 2e18);
        assertEq(token.allowance(ALICE, SPENDER), 0);
    }

    function test_poolAndDistributorOperatorsStillNeedApproval() public {
        address distributor = address(0xD157);
        factory.setDistributor(7, distributor);
        address[2] memory operators = [POOL, distributor];
        for (uint256 i; i < operators.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, operators[i], 0, 100e18)
            );
            vm.prank(operators[i]);
            token.transferFrom(ALICE, BOB, 100e18);
            _assertBalances(SUPPLY, 0, 0);
        }
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_transferFromFailureIsAtomic(uint256 held, uint256 excess, bool exemptOperator) public {
        held = bound(held, 0, SUPPLY);
        excess = bound(excess, 1, SUPPLY);
        // Move the remainder back through the exempt factory without creating fees.
        vm.prank(ALICE);
        token.transfer(address(factory), SUPPLY - held);
        address operator = exemptOperator ? address(factory) : SPENDER;
        uint256 amount = held + excess;
        _approve(operator, amount);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, held, amount));
        vm.prank(operator);
        token.transferFrom(ALICE, BOB, amount);
        assertEq(token.balanceOf(ALICE), held);
        assertEq(token.balanceOf(address(factory)), SUPPLY - held);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.balanceOf(FEE_WALLET), 0);
        assertEq(token.allowance(ALICE, operator), amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_feeRoundsDownToNearestMinorUnit(uint256 amount) public view {
        // All economically reachable transfer amounts, including the full supply.
        amount = bound(amount, 0, SUPPLY);
        uint256 fee = token.feeOn(amount);
        assertLe(fee * 50, amount);
        assertLt(amount, (fee + 1) * 50);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_walletRoundTripLosesExactlyFees(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.prank(ALICE);
        token.transfer(BOB, amount);
        uint256 arrived = token.balanceOf(BOB);
        assertEq(arrived, amount - amount / 50);
        vm.prank(BOB);
        token.transfer(ALICE, arrived);
        uint256 expectedLoss = amount / 50 + arrived / 50;
        _assertBalances(SUPPLY - expectedLoss, 0, expectedLoss);
        assertLe(token.balanceOf(ALICE), SUPPLY);
    }

    function _approve(address spender, uint256 amount) private {
        vm.prank(ALICE);
        assertTrue(token.approve(spender, amount));
    }

    function _assertFailedBalanceSpend(uint256 amount, uint256 allowance, address spender) private {
        _approve(spender, allowance);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, SUPPLY, amount));
        vm.prank(spender);
        token.transferFrom(ALICE, BOB, amount);
        _assertBalances(SUPPLY, 0, 0);
        assertEq(token.allowance(ALICE, spender), allowance);
    }

    function _assertBalances(uint256 alice, uint256 bob, uint256 fee) private view {
        assertEq(token.balanceOf(ALICE), alice);
        assertEq(token.balanceOf(BOB), bob);
        assertEq(token.balanceOf(FEE_WALLET), fee);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
