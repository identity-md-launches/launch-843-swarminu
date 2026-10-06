// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {stdError} from "forge-std/StdError.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {SwarmInu} from "src/SwarmInu.sol";
import {MockProjectFactory} from "./utils/FactoryMocks.sol";
import {ClaimsHolder} from "./SwarmInuClaims.t.sol";

/// @dev Uses the actual vendored v4 PoolManager, without a fork or a pool. Claims are liabilities
/// against the manager's SI reserves. Donations are tracked separately from redeemable claims.
contract SwarmInuClaimsHandler is Test {
    uint256 private constant SUPPLY = 1_000_000_000e18;
    address public constant FEE_WALLET = 0x66522f25035C3FAFd2c6D950a506FDa457E06344;
    PoolManager public immutable manager;
    MockProjectFactory public immutable factory;
    SwarmInu public immutable token;
    uint256 public immutable claimId;
    ClaimsHolder[3] public holders;
    uint256[3] public expectedClaims;
    uint256 public deposited;
    uint256 public redeemed;
    uint256 public donated;
    uint256 public expectedFees;

    constructor() {
        manager = new PoolManager(address(this));
        factory = new MockProjectFactory();
        token = factory.deployToken(address(manager), 7);
        claimId = uint256(uint160(address(token)));
        for (uint256 i; i < holders.length; ++i) {
            holders[i] = new ClaimsHolder(manager, token);
            factory.move(token, address(holders[i]), SUPPLY / 5);
            // Each actor starts with spendable SI and redeemable claims.
            holders[i].wrap(SUPPLY / 10);
            deposited += SUPPLY / 10;
            expectedClaims[i] = SUPPLY / 10;
        }
    }

    function wrap(uint256 actorSeed, uint256 amountSeed) external {
        uint256 actor = actorSeed % 3;
        uint256 amount = _amount(amountSeed, token.balanceOf(address(holders[actor])));
        holders[actor].wrap(amount);
        expectedClaims[actor] += amount;
        deposited += amount;
    }

    function redeem(uint256 actorSeed, uint256 recipientSeed, uint256 amountSeed) external {
        uint256 actor = actorSeed % 3;
        address recipient = address(holders[recipientSeed % 3]);
        uint256 amount = _amount(amountSeed, expectedClaims[actor]);
        uint256 before = token.balanceOf(recipient);
        holders[actor].unwrap(recipient, amount);
        expectedClaims[actor] -= amount;
        redeemed += amount;
        expectedFees += amount / 50;
        assertEq(token.balanceOf(recipient) - before, amount - amount / 50, "redemption net payout");
    }

    function moveClaims(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        uint256 from = fromSeed % 3;
        uint256 to = toSeed % 3;
        uint256 amount = _amount(amountSeed, expectedClaims[from]);
        vm.prank(address(holders[from]));
        assertTrue(manager.transfer(address(holders[to]), claimId, amount));
        expectedClaims[from] -= amount;
        expectedClaims[to] += amount;
    }

    function donate(uint256 actorSeed, uint256 amountSeed) external {
        address actor = address(holders[actorSeed % 3]);
        uint256 amount = _amount(amountSeed, token.balanceOf(actor));
        vm.prank(actor);
        assertTrue(token.transfer(address(manager), amount));
        donated += amount;
    }

    function rejectExcessRedemption(uint256 actorSeed, uint256 recipientSeed) external {
        uint256 actor = actorSeed % 3;
        address recipient = address(holders[recipientSeed % 3]);
        uint256 before = token.balanceOf(recipient);
        // The actual ERC-6909 balance check must reject, even when other holders or donations back the manager.
        vm.expectRevert(stdError.arithmeticError);
        holders[actor].unwrap(recipient, expectedClaims[actor] + 1);
        assertEq(token.balanceOf(recipient), before);
    }

    function rejectUnfundedWrap(uint256 actorSeed) external {
        uint256 actor = actorSeed % 3;
        address owner = address(holders[actor]);
        uint256 balance = token.balanceOf(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, balance, balance + 1)
        );
        holders[actor].wrap(balance + 1);
        assertEq(token.balanceOf(owner), balance);
    }

    function _amount(uint256 seed, uint256 limit) private pure returns (uint256) {
        if (seed % 4 == 0) return 0;
        if (seed % 4 == 1) return limit;
        return bound(seed, 0, limit);
    }
}

contract SwarmInuClaimsInvariantTest is Test {
    SwarmInuClaimsHandler private handler;
    SwarmInu private token;
    PoolManager private manager;

    function setUp() public {
        handler = new SwarmInuClaimsHandler();
        token = handler.token();
        manager = handler.manager();
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.wrap.selector;
        selectors[1] = handler.redeem.selector;
        selectors[2] = handler.moveClaims.selector;
        selectors[3] = handler.donate.selector;
        selectors[4] = handler.rejectExcessRedemption.selector;
        selectors[5] = handler.rejectUnfundedWrap.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_claimsRemainFullyBackedAndFeesAreConserved() public view {
        uint256 claims;
        uint256 holderBalances;
        for (uint256 i; i < 3; ++i) {
            address holder = address(handler.holders(i));
            uint256 balance = manager.balanceOf(holder, handler.claimId());
            assertEq(balance, handler.expectedClaims(i), "claims disagree with deposits, transfers and redemptions");
            claims += balance;
            holderBalances += token.balanceOf(holder);
        }
        assertEq(claims, handler.deposited() - handler.redeemed(), "unbacked or lost claims");
        assertEq(token.balanceOf(address(manager)), claims + handler.donated(), "SI reserve accounting");
        assertEq(token.balanceOf(handler.FEE_WALLET()), handler.expectedFees(), "fees only charged on redemption");
        assertEq(token.totalSupply(), 1_000_000_000e18);
        assertEq(
            holderBalances + token.balanceOf(address(handler.factory())) + token.balanceOf(address(manager))
                + token.balanceOf(handler.FEE_WALLET()),
            token.totalSupply(),
            "all underlying SI remains accounted for"
        );
    }

    function test_claimLifecycleCannotSpendDonationsOrRedeemTwice() public {
        handler.wrap(0, 1); // Full wallet balance.
        invariant_claimsRemainFullyBackedAndFeesAreConserved();
        handler.moveClaims(0, 1, 1); // Full claim balance, now belonging to holder 1.
        invariant_claimsRemainFullyBackedAndFeesAreConserved();
        handler.donate(2, 1);
        invariant_claimsRemainFullyBackedAndFeesAreConserved();
        handler.rejectExcessRedemption(1, 1);
        invariant_claimsRemainFullyBackedAndFeesAreConserved();
        handler.redeem(1, 1, 1);
        invariant_claimsRemainFullyBackedAndFeesAreConserved();
        handler.rejectExcessRedemption(1, 1);
        handler.rejectUnfundedWrap(2);
        invariant_claimsRemainFullyBackedAndFeesAreConserved();
        assertGt(handler.expectedFees(), 0);
        assertGt(handler.donated(), 0);
    }
}
