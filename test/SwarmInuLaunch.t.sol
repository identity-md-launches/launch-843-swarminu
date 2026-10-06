// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SwarmInu} from "../src/SwarmInu.sol";
import {LaunchMath, MockLaunchFactory, PairToken, Trader, PoolManagerRelay} from "./utils/LaunchHarness.sol";

/// @notice The launch as the factory performs it, against a real Uniswap v4 PoolManager: the swarm's tenth goes to
/// the distributor, the pool opens at a 400 IMD market cap, the rest of the supply seeds it single-sided with no
/// IMD at all, and an ordinary trader buys and sells.
/// @dev The pool's fee tier and tick spacing here are illustrative, and the pool carries no hook; the network's
/// manifest and deployer choose the real ones. The IMD stand-in is placed below and above the token's address so
/// both currency orders are exercised.
contract SwarmInuLaunchTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 constant SUPPLY = 1_000_000_000e18;
    uint256 constant MARKET_CAP = 400e18;
    uint256 constant SWARM_BPS = 1_000;
    uint256 constant POOL_BPS = 9_000;
    uint24 constant POOL_FEE = 10_000;
    int24 constant TICK_SPACING = 200;
    uint64 constant LAUNCH = 42;

    address constant FEE_RECIPIENT = 0x66522f25035C3FAFd2c6D950a506FDa457E06344;
    address constant LOW_PAIR = address(0x1000);
    address constant HIGH_PAIR = address(type(uint160).max - 0xfff);
    address constant DISTRIBUTOR = address(0xD157);
    address constant REQUESTER = address(0x4E0);
    address constant CLAIMANT = address(0xC1A1);
    address constant BOB = address(0xB0B);

    struct Launch {
        SwarmInu token;
        PairToken imd;
        PoolKey key;
        bool tokenIsCurrency0;
        uint160 sqrtPrice;
        int24 tickLower;
        int24 tickUpper;
        uint256 seeded;
    }

    IPoolManager manager;
    MockLaunchFactory factory;

    function setUp() public {
        manager = new PoolManager(address(this));
        factory = new MockLaunchFactory();
    }

    // ---------------------------------------------------------------- the launch

    function test_launchSeedsSingleSided_tokenAsCurrency0() public {
        _assertLaunch(_launch(HIGH_PAIR), true);
    }

    function test_launchSeedsSingleSided_tokenAsCurrency1() public {
        _assertLaunch(_launch(LOW_PAIR), false);
    }

    function _assertLaunch(Launch memory l, bool tokenIsCurrency0) private {
        assertEq(l.tokenIsCurrency0, tokenIsCurrency0);
        uint256 swarm = (SUPPLY * SWARM_BPS) / 10_000;
        uint256 allowed = (SUPPLY * POOL_BPS) / 10_000;

        assertEq(l.token.balanceOf(DISTRIBUTOR), swarm, "the swarm's share arrived whole");
        assertLe(l.seeded, allowed, "the seed took no more than the pool share");
        assertGt(l.seeded, allowed - 1e9, "the seed used the pool share bar rounding dust");
        assertEq(l.token.balanceOf(address(manager)), l.seeded, "the seed arrived whole");
        assertEq(l.imd.balanceOf(address(manager)), 0, "no IMD was added");
        assertEq(l.imd.totalSupply(), 0, "no IMD was needed anywhere");
        assertGt(
            manager.getPositionLiquidity(
                l.key.toId(), keccak256(abi.encodePacked(address(factory), l.tickLower, l.tickUpper, bytes32(0)))
            ),
            0
        );
        assertEq(manager.getLiquidity(l.key.toId()), 0, "the opening price sits outside the seeded range");

        // The factory forwards what the seed left over, and a contributor claims: both exact.
        uint256 remainder = l.token.balanceOf(address(factory));
        assertEq(remainder, allowed - l.seeded);
        factory.move(l.token, REQUESTER, remainder);
        assertEq(l.token.balanceOf(REQUESTER), remainder);
        vm.prank(DISTRIBUTOR);
        l.token.transfer(CLAIMANT, swarm);
        assertEq(l.token.balanceOf(CLAIMANT), swarm, "a claim arrived whole");

        assertEq(l.token.balanceOf(FEE_RECIPIENT), 0, "no launch flow paid the fee");
        assertEq(l.token.totalSupply(), SUPPLY);
        assertEq(l.seeded + remainder + swarm, SUPPLY, "every token is accounted for");
    }

    function test_openingPriceIsA400ImdMarketCap() public pure {
        // The values the README quotes for the two currency orders.
        uint160 asCurrency0 = LaunchMath.sqrtPriceX96(true, SUPPLY, MARKET_CAP);
        uint160 asCurrency1 = LaunchMath.sqrtPriceX96(false, SUPPLY, MARKET_CAP);
        assertEq(asCurrency0, 50108289675009586237282760);
        assertEq(asCurrency1, 125270724187523965593206900784803);

        // price = IMD per SI = (sqrtPrice / 2^96)^2, so market cap = price * supply.
        uint256 capFrom0 = FullMath.mulDiv(FullMath.mulDiv(asCurrency0, asCurrency0, 1 << 96), SUPPLY, 1 << 96);
        assertApproxEqRel(capFrom0, MARKET_CAP, 1e9);
        // price = SI per IMD, so market cap = supply / price.
        uint256 capFrom1 = FullMath.mulDiv(SUPPLY, 1 << 96, FullMath.mulDiv(asCurrency1, asCurrency1, 1 << 96));
        assertApproxEqRel(capFrom1, MARKET_CAP, 1e9);
    }

    // ---------------------------------------------------------------- trading

    function test_traderBuysAndSellsExactly_tokenAsCurrency0() public {
        _assertBuyAndSell(_launch(HIGH_PAIR));
    }

    function test_traderBuysAndSellsExactly_tokenAsCurrency1() public {
        _assertBuyAndSell(_launch(LOW_PAIR));
    }

    function _assertBuyAndSell(Launch memory l) private {
        Trader trader = new Trader(manager);
        l.imd.mint(address(trader), 10e18);
        bool buyIsZeroForOne = !l.tokenIsCurrency0;

        // Buy: 0.01 IMD in, SI out. The pool manager pays out exactly the swap's delta.
        BalanceDelta buy = trader.swap(l.key, buyIsZeroForOne, -0.01e18);
        uint256 bought = uint256(int256(l.tokenIsCurrency0 ? buy.amount0() : buy.amount1()));
        assertGt(bought, 0);
        assertEq(l.token.balanceOf(address(trader)), bought, "the buy arrived whole");
        assertEq(l.imd.balanceOf(address(trader)), 10e18 - 0.01e18);
        assertEq(l.imd.balanceOf(address(manager)), 0.01e18);

        // At a 400 IMD cap one SI costs 4e-7 IMD. The seeded range starts within one tick spacing (2.02%) above
        // that, and the pool keeps its 1% fee, so 0.01 IMD buys a little under 25,000 SI.
        assertLt(bought, 25_000e18);
        assertGt(bought, 24_000e18);

        // Sell everything back: the pool manager is credited exactly what the trader sends.
        BalanceDelta sell = trader.swap(l.key, !buyIsZeroForOne, -int256(bought));
        uint256 received = uint256(int256(l.tokenIsCurrency0 ? sell.amount1() : sell.amount0()));
        assertEq(l.token.balanceOf(address(trader)), 0, "the sell left nothing behind");
        assertGt(received, 0);
        assertLt(received, 0.01e18, "a round trip costs the pool's fee twice");
        assertEq(l.imd.balanceOf(address(trader)), 10e18 - 0.01e18 + received);

        assertEq(l.token.balanceOf(FEE_RECIPIENT), 0, "swaps against the pool manager pay no token fee");
        assertEq(
            l.token.balanceOf(address(manager)) + l.token.balanceOf(DISTRIBUTOR) + l.token.balanceOf(address(factory)),
            SUPPLY,
            "every token is back where the launch put it"
        );
        assertEq(l.token.totalSupply(), SUPPLY);
    }

    function test_boughtTokensPayTheFeeOnceTheyMoveBetweenWallets() public {
        Launch memory l = _launch(HIGH_PAIR);
        Trader trader = new Trader(manager);
        l.imd.mint(address(trader), 1e18);
        trader.swap(l.key, !l.tokenIsCurrency0, -0.01e18);
        uint256 bought = l.token.balanceOf(address(trader));

        trader.send(address(l.token), BOB, bought);

        uint256 fee = (bought * 200) / 10_000;
        assertEq(l.token.balanceOf(BOB), bought - fee);
        assertEq(l.token.balanceOf(FEE_RECIPIENT), fee);
    }

    function test_buyingRaisesThePrice() public {
        Launch memory l = _launch(HIGH_PAIR);
        Trader trader = new Trader(manager);
        l.imd.mint(address(trader), 100e18);

        trader.swap(l.key, false, -1e18);
        uint256 first = l.token.balanceOf(address(trader));
        trader.swap(l.key, false, -1e18);
        uint256 second = l.token.balanceOf(address(trader)) - first;

        assertLt(second, first, "the same IMD buys fewer SI after a buy");
        (uint160 sqrtPrice,,,) = manager.getSlot0(l.key.toId());
        assertGt(sqrtPrice, l.sqrtPrice);
    }

    /// @dev A documented limit, not a feature: because the pool manager must be exempt for swaps to settle, a
    /// holder who pays tokens into it and takes them out to another wallet moves them without the fee.
    function test_knownLimit_transferRoutedThroughThePoolManagerPaysNoFee() public {
        Launch memory l = _launch(HIGH_PAIR);
        PoolManagerRelay relay = new PoolManagerRelay(manager);
        // Funded from the distributor, so the relay starts with a round amount.
        vm.prank(DISTRIBUTOR);
        l.token.transfer(address(relay), 100e18);

        relay.relay(Currency.wrap(address(l.token)), BOB, 100e18);

        assertEq(l.token.balanceOf(BOB), 100e18);
        assertEq(l.token.balanceOf(FEE_RECIPIENT), 0);
    }

    // ---------------------------------------------------------------- failures

    function test_seedSpanningTheOpeningPriceNeedsImdAndReverts() public {
        (SwarmInu token,, PoolKey memory key, bool tokenIsCurrency0) = _deploy(HIGH_PAIR);
        uint160 sqrtPrice = LaunchMath.sqrtPriceX96(tokenIsCurrency0, SUPPLY, MARKET_CAP);
        factory.initialize(manager, key, sqrtPrice);
        (int24 tickLower, int24 tickUpper) = LaunchMath.singleSidedRange(tokenIsCurrency0, sqrtPrice, TICK_SPACING);

        // One spacing lower and the range holds the opening price, so the pool asks for IMD the factory lacks.
        vm.expectRevert();
        factory.seed(manager, MockLaunchFactory.Seed(key, tickLower - TICK_SPACING, tickUpper, 1e18));
        assertEq(token.balanceOf(address(manager)), 0);
    }

    function test_seedBeyondTheFactorysBalanceReverts() public {
        (SwarmInu token,, PoolKey memory key, bool tokenIsCurrency0) = _deploy(LOW_PAIR);
        uint160 sqrtPrice = LaunchMath.sqrtPriceX96(tokenIsCurrency0, SUPPLY, MARKET_CAP);
        factory.initialize(manager, key, sqrtPrice);
        (int24 tickLower, int24 tickUpper) = LaunchMath.singleSidedRange(tokenIsCurrency0, sqrtPrice, TICK_SPACING);
        uint128 liquidity = LaunchMath.liquidityForAmount(tokenIsCurrency0, tickLower, tickUpper, 2 * SUPPLY);

        vm.expectRevert();
        factory.seed(manager, MockLaunchFactory.Seed(key, tickLower, tickUpper, liquidity));
        assertEq(token.balanceOf(address(factory)), SUPPLY);
    }

    function test_sellingMoreThanHeldReverts() public {
        Launch memory l = _launch(LOW_PAIR);
        Trader trader = new Trader(manager);
        l.imd.mint(address(trader), 1e18);
        trader.swap(l.key, !l.tokenIsCurrency0, -0.01e18);
        uint256 bought = l.token.balanceOf(address(trader));

        vm.expectRevert();
        trader.swap(l.key, l.tokenIsCurrency0, -int256(bought + 1));
        assertEq(l.token.balanceOf(address(trader)), bought);
    }

    function test_buyingWithoutImdReverts() public {
        Launch memory l = _launch(LOW_PAIR);
        Trader trader = new Trader(manager);

        vm.expectRevert();
        trader.swap(l.key, !l.tokenIsCurrency0, -0.01e18);
        assertEq(l.token.balanceOf(address(trader)), 0);
    }

    // ---------------------------------------------------------------- scaffolding

    function _deploy(address pairAt)
        private
        returns (SwarmInu token, PairToken imd, PoolKey memory key, bool tokenIsCurrency0)
    {
        vm.etch(pairAt, address(new PairToken()).code);
        imd = PairToken(pairAt);
        token = factory.deployToken(address(manager), LAUNCH);
        factory.setDistributor(LAUNCH, DISTRIBUTOR);
        tokenIsCurrency0 = address(token) < pairAt;
        (Currency currency0, Currency currency1) = tokenIsCurrency0
            ? (Currency.wrap(address(token)), Currency.wrap(pairAt))
            : (Currency.wrap(pairAt), Currency.wrap(address(token)));
        key = PoolKey(currency0, currency1, POOL_FEE, TICK_SPACING, IHooks(address(0)));
    }

    function _launch(address pairAt) private returns (Launch memory l) {
        (l.token, l.imd, l.key, l.tokenIsCurrency0) = _deploy(pairAt);
        factory.move(l.token, DISTRIBUTOR, (SUPPLY * SWARM_BPS) / 10_000);

        l.sqrtPrice = LaunchMath.sqrtPriceX96(l.tokenIsCurrency0, SUPPLY, MARKET_CAP);
        factory.initialize(manager, l.key, l.sqrtPrice);
        (l.tickLower, l.tickUpper) = LaunchMath.singleSidedRange(l.tokenIsCurrency0, l.sqrtPrice, TICK_SPACING);
        uint128 liquidity =
            LaunchMath.liquidityForAmount(l.tokenIsCurrency0, l.tickLower, l.tickUpper, (SUPPLY * POOL_BPS) / 10_000);

        uint256 before = l.token.balanceOf(address(factory));
        factory.seed(manager, MockLaunchFactory.Seed(l.key, l.tickLower, l.tickUpper, liquidity));
        l.seeded = before - l.token.balanceOf(address(factory));
    }
}
