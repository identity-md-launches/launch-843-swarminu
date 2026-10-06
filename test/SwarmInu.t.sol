// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SwarmInu} from "../src/SwarmInu.sol";
import {
    MockProjectFactory,
    RevertingFactory,
    GasBurningFactory,
    ShortAnswerFactory,
    DirtyAnswerFactory,
    OversizedAnswerFactory
} from "./utils/FactoryMocks.sol";

contract SwarmInuTest is Test {
    uint256 constant SUPPLY = 1_000_000_000e18;
    address constant FEE_RECIPIENT = 0x66522f25035C3FAFd2c6D950a506FDa457E06344;
    uint64 constant LAUNCH = 7;

    address constant POOL_MANAGER = address(0x9001);
    address constant DISTRIBUTOR = address(0xD157);
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    address constant CAROL = address(0xCA201);

    MockProjectFactory factory;
    SwarmInu token;

    function setUp() public {
        factory = new MockProjectFactory();
        token = factory.deployToken(POOL_MANAGER, LAUNCH);
    }

    // ---------------------------------------------------------------- deployment

    function test_metadata() public view {
        assertEq(token.name(), "SwarmInu");
        assertEq(token.symbol(), "SI");
        assertEq(token.decimals(), 18);
        assertEq(token.FEE_BPS(), 200);
        assertEq(token.FEE_RECIPIENT(), FEE_RECIPIENT);
        assertEq(token.factory(), address(factory));
        assertEq(token.poolManager(), POOL_MANAGER);
        assertEq(token.launchNumber(), LAUNCH);
    }

    function test_wholeSupplyIsMintedOnceToTheDeployer() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
        assertEq(token.balanceOf(address(factory)), SUPPLY);
        assertEq(token.balanceOf(FEE_RECIPIENT), 0);
    }

    function test_supplyGoesToTheDeployerEvenWhenItIsNotTheFactory() public {
        SwarmInu direct = new SwarmInu(address(factory), POOL_MANAGER, LAUNCH);
        assertEq(direct.balanceOf(address(this)), SUPPLY);
        assertEq(direct.balanceOf(address(factory)), 0);
    }

    function test_constructorRejectsAZeroFactory() public {
        vm.expectRevert(SwarmInu.ZeroAddress.selector);
        new SwarmInu(address(0), POOL_MANAGER, LAUNCH);
    }

    function test_constructorRejectsAZeroPoolManager() public {
        vm.expectRevert(SwarmInu.ZeroAddress.selector);
        new SwarmInu(address(factory), address(0), LAUNCH);
    }

    // ---------------------------------------------------------------- the fee

    function test_ordinaryTransferPaysTwoPercentToTheRecipient() public {
        factory.move(token, ALICE, 1_000e18);

        vm.expectEmit(address(token));
        emit IERC20.Transfer(ALICE, FEE_RECIPIENT, 2e18);
        vm.expectEmit(address(token));
        emit IERC20.Transfer(ALICE, BOB, 98e18);
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 100e18));

        assertEq(token.balanceOf(ALICE), 900e18, "sender is debited exactly the amount sent");
        assertEq(token.balanceOf(BOB), 98e18);
        assertEq(token.balanceOf(FEE_RECIPIENT), 2e18);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferFromPaysTheFeeAndSpendsTheFullAllowance() public {
        factory.move(token, ALICE, 1_000e18);
        vm.prank(ALICE);
        token.approve(CAROL, 150e18);

        vm.prank(CAROL);
        assertTrue(token.transferFrom(ALICE, BOB, 100e18));

        assertEq(token.balanceOf(ALICE), 900e18);
        assertEq(token.balanceOf(BOB), 98e18);
        assertEq(token.balanceOf(FEE_RECIPIENT), 2e18);
        assertEq(token.allowance(ALICE, CAROL), 50e18);
    }

    function test_selfTransferStillPaysTheFee() public {
        factory.move(token, ALICE, 1_000e18);
        vm.prank(ALICE);
        token.transfer(ALICE, 100e18);
        assertEq(token.balanceOf(ALICE), 998e18);
        assertEq(token.balanceOf(FEE_RECIPIENT), 2e18);
    }

    function test_feeRoundsDownSoDustBelowFiftyWeiIsFree() public {
        factory.move(token, ALICE, 1_000e18);
        vm.startPrank(ALICE);
        token.transfer(BOB, 49);
        assertEq(token.balanceOf(BOB), 49);
        assertEq(token.balanceOf(FEE_RECIPIENT), 0);
        token.transfer(BOB, 50);
        assertEq(token.balanceOf(BOB), 49 + 49);
        assertEq(token.balanceOf(FEE_RECIPIENT), 1);
        vm.stopPrank();
    }

    function test_zeroValueTransferSucceedsAndPaysNothing() public {
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 0));
        assertEq(token.balanceOf(FEE_RECIPIENT), 0);
    }

    function test_feeOn() public view {
        assertEq(token.feeOn(0), 0);
        assertEq(token.feeOn(49), 0);
        assertEq(token.feeOn(50), 1);
        assertEq(token.feeOn(100e18), 2e18);
        assertEq(token.feeOn(SUPPLY), SUPPLY / 50);
    }

    function testFuzz_ordinaryTransferConservesValue(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != ALICE);
        vm.assume(!token.isFeeExempt(ALICE, ALICE, to));
        factory.move(token, ALICE, SUPPLY);
        amount = bound(amount, 0, SUPPLY);
        uint256 toBefore = token.balanceOf(to);

        vm.prank(ALICE);
        token.transfer(to, amount);

        uint256 fee = (amount * 200) / 10_000;
        assertEq(token.balanceOf(ALICE), SUPPLY - amount);
        assertEq(token.balanceOf(to), toBefore + amount - fee);
        assertEq(token.balanceOf(FEE_RECIPIENT), fee);
        assertEq(token.totalSupply(), SUPPLY);
    }

    // ---------------------------------------------------------------- exemptions

    function test_factoryMovesExactAmounts() public {
        vm.recordLogs();
        assertTrue(factory.move(token, ALICE, 100e18));
        assertEq(vm.getRecordedLogs().length, 1, "a single Transfer event");
        assertEq(token.balanceOf(ALICE), 100e18);
        assertEq(token.balanceOf(FEE_RECIPIENT), 0);
    }

    function test_factoryAsSpenderMovesExactAmounts() public {
        factory.move(token, ALICE, 100e18);
        vm.prank(ALICE);
        token.approve(address(factory), 100e18);
        factory.pull(token, ALICE, BOB, 100e18);
        assertEq(token.balanceOf(BOB), 100e18);
        assertEq(token.balanceOf(FEE_RECIPIENT), 0);
    }

    function test_transfersToTheFactoryAreExact() public {
        factory.move(token, ALICE, 100e18);
        uint256 before = token.balanceOf(address(factory));
        vm.prank(ALICE);
        token.transfer(address(factory), 100e18);
        assertEq(token.balanceOf(address(factory)), before + 100e18);
        assertEq(token.balanceOf(FEE_RECIPIENT), 0);
    }

    function test_transfersIntoThePoolManagerAreExactAndPayoutsPayTheFee() public {
        factory.move(token, ALICE, 100e18);

        vm.prank(ALICE);
        token.transfer(POOL_MANAGER, 100e18);
        assertEq(token.balanceOf(POOL_MANAGER), 100e18, "a sell settles in full");
        assertEq(token.balanceOf(FEE_RECIPIENT), 0);

        vm.prank(POOL_MANAGER);
        token.transfer(BOB, 100e18);
        assertEq(token.balanceOf(BOB), 98e18, "a buy is paid net of the fee");
        assertEq(token.balanceOf(FEE_RECIPIENT), 2e18);
        assertEq(token.balanceOf(POOL_MANAGER), 0, "the manager is debited the full payout");
    }

    function test_transferFromIntoThePoolManagerIsExact() public {
        factory.move(token, ALICE, 100e18);
        vm.prank(ALICE);
        token.approve(CAROL, 100e18);
        // A router paying the pool manager from the trader's wallet.
        vm.prank(CAROL);
        token.transferFrom(ALICE, POOL_MANAGER, 100e18);
        assertEq(token.balanceOf(POOL_MANAGER), 100e18);
        assertEq(token.balanceOf(FEE_RECIPIENT), 0);
    }

    function test_distributorFundingAndClaimsAreExact() public {
        factory.setDistributor(LAUNCH, DISTRIBUTOR);
        assertEq(token.distributor(), DISTRIBUTOR);
        uint256 swarm = SUPPLY / 10;

        factory.move(token, DISTRIBUTOR, swarm);
        assertEq(token.balanceOf(DISTRIBUTOR), swarm);

        vm.prank(DISTRIBUTOR);
        token.transfer(ALICE, swarm);
        assertEq(token.balanceOf(ALICE), swarm, "a claim arrives whole");
        assertEq(token.balanceOf(DISTRIBUTOR), 0);

        vm.prank(ALICE);
        token.transfer(DISTRIBUTOR, 1e18);
        assertEq(token.balanceOf(DISTRIBUTOR), 1e18);
        assertEq(token.balanceOf(FEE_RECIPIENT), 0);
    }

    function test_claimedTokensPayTheFeeWhenTheClaimantMovesThem() public {
        factory.setDistributor(LAUNCH, DISTRIBUTOR);
        factory.move(token, DISTRIBUTOR, 100e18);
        vm.prank(DISTRIBUTOR);
        token.transfer(ALICE, 100e18);

        vm.prank(ALICE);
        token.transfer(BOB, 100e18);
        assertEq(token.balanceOf(BOB), 98e18);
        assertEq(token.balanceOf(FEE_RECIPIENT), 2e18);
    }

    function test_distributorOfAnotherLaunchIsNotExempt() public {
        factory.setDistributor(LAUNCH + 1, DISTRIBUTOR);
        assertEq(token.distributor(), address(0));
        factory.move(token, DISTRIBUTOR, 100e18);

        vm.prank(DISTRIBUTOR);
        token.transfer(ALICE, 100e18);
        assertEq(token.balanceOf(ALICE), 98e18);
        assertEq(token.balanceOf(FEE_RECIPIENT), 2e18);
    }

    function test_exemptionFollowsTheFactorysCurrentAnswer() public {
        factory.move(token, DISTRIBUTOR, 200e18);

        // Not registered yet: taxed like anyone else.
        vm.prank(DISTRIBUTOR);
        token.transfer(ALICE, 100e18);
        assertEq(token.balanceOf(ALICE), 98e18);

        factory.setDistributor(LAUNCH, DISTRIBUTOR);
        vm.prank(DISTRIBUTOR);
        token.transfer(BOB, 100e18);
        assertEq(token.balanceOf(BOB), 100e18);
        assertEq(token.balanceOf(FEE_RECIPIENT), 2e18);
    }

    function test_feeRecipientSendsAndReceivesWithoutAFee() public {
        factory.move(token, ALICE, 100e18);
        vm.prank(ALICE);
        token.transfer(FEE_RECIPIENT, 100e18);
        assertEq(token.balanceOf(FEE_RECIPIENT), 100e18);

        vm.prank(FEE_RECIPIENT);
        token.transfer(BOB, 100e18);
        assertEq(token.balanceOf(BOB), 100e18);
        assertEq(token.balanceOf(FEE_RECIPIENT), 0);
    }

    function test_isFeeExempt() public {
        factory.setDistributor(LAUNCH, DISTRIBUTOR);
        assertFalse(token.isFeeExempt(ALICE, ALICE, BOB));
        assertFalse(token.isFeeExempt(CAROL, ALICE, BOB));
        assertFalse(token.isFeeExempt(POOL_MANAGER, ALICE, BOB), "the pool manager is only exempt as a recipient");
        assertFalse(token.isFeeExempt(DISTRIBUTOR, ALICE, BOB));
        assertTrue(token.isFeeExempt(address(factory), ALICE, BOB));
        assertTrue(token.isFeeExempt(ALICE, address(factory), BOB));
        assertTrue(token.isFeeExempt(ALICE, ALICE, address(factory)));
        assertTrue(token.isFeeExempt(ALICE, ALICE, POOL_MANAGER));
        assertFalse(token.isFeeExempt(ALICE, POOL_MANAGER, BOB));
        assertTrue(token.isFeeExempt(ALICE, ALICE, DISTRIBUTOR));
        assertTrue(token.isFeeExempt(ALICE, DISTRIBUTOR, BOB));
        assertTrue(token.isFeeExempt(ALICE, ALICE, FEE_RECIPIENT));
        assertTrue(token.isFeeExempt(ALICE, FEE_RECIPIENT, BOB));
    }

    function test_nobodyCanExemptThemselves() public {
        factory.move(token, ALICE, 100e18);
        // Only the factory's own record names the distributor; a stranger's claim to be one changes nothing.
        MockProjectFactory impostor = new MockProjectFactory();
        impostor.setDistributor(LAUNCH, ALICE);

        vm.prank(ALICE);
        token.transfer(BOB, 100e18);
        assertEq(token.balanceOf(BOB), 98e18);
    }

    // ---------------------------------------------------------------- a factory that does not answer

    function test_factoryWithoutCodeMeansNoDistributor() public {
        _assertOrdinaryTransferStillWorks(new SwarmInu(address(0xFAC7), POOL_MANAGER, LAUNCH));
    }

    function test_revertingFactoryMeansNoDistributor() public {
        _assertOrdinaryTransferStillWorks(new SwarmInu(address(new RevertingFactory()), POOL_MANAGER, LAUNCH));
    }

    function test_shortAnswerMeansNoDistributor() public {
        _assertOrdinaryTransferStillWorks(new SwarmInu(address(new ShortAnswerFactory()), POOL_MANAGER, LAUNCH));
    }

    function test_dirtyAnswerMeansNoDistributor() public {
        SwarmInu t = new SwarmInu(address(new DirtyAnswerFactory(address(this))), POOL_MANAGER, LAUNCH);
        _assertOrdinaryTransferStillWorks(t);
    }

    function test_gasBurningFactoryCannotFreezeTransfers() public {
        SwarmInu t = new SwarmInu(address(new GasBurningFactory()), POOL_MANAGER, LAUNCH);
        uint256 gasBefore = gasleft();
        _assertOrdinaryTransferStillWorks(t);
        // The lookup is capped, so the worst a factory can do is make a transfer cost the cap more.
        assertLt(gasBefore - gasleft(), 2 * t.DISTRIBUTOR_LOOKUP_GAS() + 150_000);
    }

    function test_oversizedAnswerIsReadAsOneWord() public {
        SwarmInu t = new SwarmInu(address(new OversizedAnswerFactory(DISTRIBUTOR)), POOL_MANAGER, LAUNCH);
        assertEq(t.distributor(), DISTRIBUTOR);
        t.transfer(DISTRIBUTOR, 100e18);
        assertEq(t.balanceOf(DISTRIBUTOR), 100e18);
    }

    function _assertOrdinaryTransferStillWorks(SwarmInu t) private {
        assertEq(t.distributor(), address(0));
        assertTrue(t.transfer(BOB, 100e18));
        assertEq(t.balanceOf(BOB), 98e18);
        assertEq(t.balanceOf(FEE_RECIPIENT), 2e18);
    }

    // ---------------------------------------------------------------- failures

    function test_transferBeyondBalanceReverts() public {
        factory.move(token, ALICE, 100e18);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 100e18, 100e18 + 1)
        );
        vm.prank(ALICE);
        token.transfer(BOB, 100e18 + 1);
    }

    function test_transferFromWithoutAllowanceReverts() public {
        factory.move(token, ALICE, 100e18);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, CAROL, 0, 1));
        vm.prank(CAROL);
        token.transferFrom(ALICE, CAROL, 1);
    }

    function test_factoryCannotMoveAHoldersBalanceWithoutAllowance() public {
        factory.move(token, ALICE, 100e18);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(factory), 0, 1)
        );
        factory.pull(token, ALICE, address(factory), 1);
        assertEq(token.balanceOf(ALICE), 100e18);
    }

    function test_feeRecipientHasNoPowerOverHolders() public {
        factory.move(token, ALICE, 100e18);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, FEE_RECIPIENT, 0, 1));
        vm.prank(FEE_RECIPIENT);
        token.transferFrom(ALICE, FEE_RECIPIENT, 1);
    }

    function test_transferToTheZeroAddressReverts() public {
        factory.move(token, ALICE, 100e18);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(ALICE);
        token.transfer(address(0), 1);
    }

    /// @dev There is no mint, burn, owner, pause or blacklist: none of these selectors exists, from anyone.
    function test_noAdministrativeSurface() public {
        factory.move(token, ALICE, 100e18);
        string[18] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "owner()",
            "setOwner(address)",
            "transferOwnership(address)",
            "renounceOwnership()",
            "pause()",
            "unpause()",
            "blacklist(address)",
            "setBlacklist(address,bool)",
            "freeze(address)",
            "seize(address)",
            "setFee(uint256)",
            "setFeeRecipient(address)",
            "setExempt(address,bool)",
            "upgradeTo(address)"
        ];
        address[3] memory callers = [address(factory), FEE_RECIPIENT, CAROL];
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], ALICE, uint256(1));
            for (uint256 j = 0; j < callers.length; j++) {
                vm.prank(callers[j]);
                (bool ok,) = address(token).call(data);
                assertFalse(ok, signatures[i]);
            }
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(ALICE), 100e18);
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 100e18));
    }

    /// @dev The launch floor scans the runtime for these opcodes, skipping push data.
    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        for (uint256 i = 0; i < runtime.length; i++) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "DELEGATECALL");
            assertTrue(op != 0xF2, "CALLCODE");
            assertTrue(op != 0xFF, "SELFDESTRUCT");
        }
    }
}
