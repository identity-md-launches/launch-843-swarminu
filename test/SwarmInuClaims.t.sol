// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwarmInu} from "../src/SwarmInu.sol";
import {MockProjectFactory} from "./utils/FactoryMocks.sol";

/// @dev Test-only holder of SI and ERC-6909 claims. No pool is initialized or used.
contract ClaimsHolder is IUnlockCallback {
    IPoolManager private immutable manager;
    SwarmInu private immutable token;

    constructor(IPoolManager manager_, SwarmInu token_) {
        manager = manager_;
        token = token_;
    }

    function wrap(uint256 amount) external {
        manager.unlock(abi.encode(true, address(this), amount));
    }

    function unwrap(address to, uint256 amount) external {
        manager.unlock(abi.encode(false, to, amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not the pool manager");
        (bool wrapping, address to, uint256 amount) = abi.decode(data, (bool, address, uint256));
        Currency currency = Currency.wrap(address(token));
        if (wrapping) {
            manager.sync(currency);
            token.transfer(address(manager), amount);
            manager.settle();
            manager.mint(to, currency.toId(), amount);
        } else {
            manager.burn(address(this), currency.toId(), amount);
            manager.take(currency, to, amount);
        }
        return "";
    }
}

contract SwarmInuClaimsTest is Test {
    address constant BOB = address(0xB0B);
    address constant CAROL = address(0xCA201);
    uint256 constant AMOUNT = 1_000e18;

    PoolManager manager;
    SwarmInu token;
    ClaimsHolder depositor;
    ClaimsHolder redeemer;
    uint256 id;

    function setUp() public {
        manager = new PoolManager(address(this));
        MockProjectFactory factory = new MockProjectFactory();
        token = factory.deployToken(address(manager), 7);
        depositor = new ClaimsHolder(manager, token);
        redeemer = new ClaimsHolder(manager, token);
        id = uint256(uint160(address(token)));
        factory.move(token, address(depositor), AMOUNT);
        depositor.wrap(AMOUNT);
    }

    function test_claimRedemptionPaysTheFeeAfterClaimsChangeHands() public {
        assertEq(token.balanceOf(address(manager)), AMOUNT);
        assertEq(manager.balanceOf(address(depositor), id), AMOUNT);
        assertEq(token.balanceOf(token.FEE_RECIPIENT()), 0, "wrapping settles in full");

        // Claim transfers do not call SI. The fee is deferred until SI is paid out.
        vm.prank(address(depositor));
        manager.transfer(BOB, id, AMOUNT);
        vm.prank(BOB);
        manager.transfer(address(redeemer), id, AMOUNT);
        redeemer.unwrap(CAROL, AMOUNT);

        assertEq(token.balanceOf(CAROL), 980e18);
        assertEq(token.balanceOf(token.FEE_RECIPIENT()), 20e18);
        assertEq(token.balanceOf(address(manager)), 0);
        assertEq(manager.balanceOf(address(depositor), id), 0);
        assertEq(manager.balanceOf(BOB, id), 0);
        assertEq(manager.balanceOf(address(redeemer), id), 0);
        assertEq(token.totalSupply(), token.TOTAL_SUPPLY());

        // Consumed claims cannot be redeemed twice, including the fee portion.
        vm.expectRevert();
        redeemer.unwrap(CAROL, AMOUNT);
        assertEq(token.balanceOf(CAROL), 980e18);
        assertEq(token.balanceOf(token.FEE_RECIPIENT()), 20e18);
    }

    function test_redeemingMoreClaimsThanHeldRevertsWithoutMovingSi() public {
        vm.expectRevert();
        depositor.unwrap(CAROL, AMOUNT + 1);
        assertEq(manager.balanceOf(address(depositor), id), AMOUNT);
        assertEq(token.balanceOf(address(manager)), AMOUNT);
        assertEq(token.balanceOf(CAROL), 0);
        assertEq(token.balanceOf(token.FEE_RECIPIENT()), 0);
    }
}
