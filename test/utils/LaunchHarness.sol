// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {MockProjectFactory} from "./FactoryMocks.sol";

interface ITransfer {
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @notice The arithmetic of a single-sided launch: the opening price a market cap implies, the range that holds
/// only the launched token at that price, and the liquidity a token amount buys in that range.
/// @dev Test scaffolding that mirrors what the network's deployer derives; it is not deployed.
library LaunchMath {
    uint256 internal constant Q96 = 1 << 96;

    /// @notice sqrt(currency1 / currency0) in Q64.96 for a token whose whole `supply` is worth `marketCap` of the
    /// paired currency (both in minor units).
    function sqrtPriceX96(bool tokenIsCurrency0, uint256 supply, uint256 marketCap) internal pure returns (uint160) {
        uint256 ratioX192 = tokenIsCurrency0
            ? FullMath.mulDiv(marketCap, 1 << 192, supply)
            : FullMath.mulDiv(supply, 1 << 192, marketCap);
        return uint160(sqrt(ratioX192));
    }

    /// @notice The widest range that holds only the launched token while the pool sits at `sqrtPrice`.
    function singleSidedRange(bool tokenIsCurrency0, uint160 sqrtPrice, int24 tickSpacing)
        internal
        pure
        returns (int24 tickLower, int24 tickUpper)
    {
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtPrice);
        int24 floored = (tick / tickSpacing) * tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) floored -= tickSpacing;
        if (tokenIsCurrency0) {
            // Only currency0 is owed while the pool's tick is strictly below the range.
            return (floored + tickSpacing, TickMath.maxUsableTick(tickSpacing));
        }
        // Only currency1 is owed while the pool's tick is at or above the range's upper tick.
        return (TickMath.minUsableTick(tickSpacing), floored);
    }

    /// @notice The liquidity `amount` of the launched token provides across a range it alone fills.
    function liquidityForAmount(bool tokenIsCurrency0, int24 tickLower, int24 tickUpper, uint256 amount)
        internal
        pure
        returns (uint128)
    {
        uint256 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint256 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        uint256 liquidity = tokenIsCurrency0
            ? FullMath.mulDiv(amount, FullMath.mulDiv(sqrtLower, sqrtUpper, Q96), sqrtUpper - sqrtLower)
            : FullMath.mulDiv(amount, Q96, sqrtUpper - sqrtLower);
        return uint128(liquidity);
    }

    function sqrt(uint256 x) internal pure returns (uint256 z) {
        if (x == 0) return 0;
        z = x;
        uint256 y = (x >> 1) + 1;
        while (y < z) {
            z = y;
            y = (x / y + y) >> 1;
        }
    }
}

/// @notice Pays or collects one currency's delta against the pool manager, for exactly the amount owed.
library Settlement {
    function settle(IPoolManager manager, Currency currency, int128 delta) internal {
        if (delta < 0) {
            manager.sync(currency);
            ITransfer(Currency.unwrap(currency)).transfer(address(manager), uint128(-delta));
            manager.settle();
        } else if (delta > 0) {
            manager.take(currency, address(this), uint128(delta));
        }
    }
}

/// @notice The factory's part of a launch: it holds the supply, opens the pool and seeds it through the pool
/// manager's unlock.
contract MockLaunchFactory is MockProjectFactory, IUnlockCallback {
    struct Seed {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    IPoolManager private manager;

    function initialize(IPoolManager manager_, PoolKey calldata key, uint160 sqrtPrice) external {
        manager_.initialize(key, sqrtPrice);
    }

    function seed(IPoolManager manager_, Seed calldata seed_) external {
        manager = manager_;
        manager_.unlock(abi.encode(seed_));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(manager), "not the pool manager");
        Seed memory seed_ = abi.decode(data, (Seed));
        (BalanceDelta delta,) = manager.modifyLiquidity(
            seed_.key,
            ModifyLiquidityParams(seed_.tickLower, seed_.tickUpper, int256(uint256(seed_.liquidity)), bytes32(0)),
            ""
        );
        Settlement.settle(manager, seed_.key.currency0, delta.amount0());
        Settlement.settle(manager, seed_.key.currency1, delta.amount1());
        return "";
    }
}

/// @notice Stands in for IMD: a plain ERC-20 whose code the tests place at a chosen address, so the pool sorts
/// its two currencies either way round.
contract PairToken {
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice An ordinary trader with no exemption of its own, swapping straight against the pool manager.
contract Trader is IUnlockCallback {
    IPoolManager private immutable manager;
    PoolKey private key;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey calldata key_, bool zeroForOne, int256 amountSpecified) external returns (BalanceDelta) {
        key = key_;
        return abi.decode(manager.unlock(abi.encode(zeroForOne, amountSpecified)), (BalanceDelta));
    }

    function send(address token, address to, uint256 amount) external {
        ITransfer(token).transfer(to, amount);
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(manager), "not the pool manager");
        (bool zeroForOne, int256 amountSpecified) = abi.decode(data, (bool, int256));
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        BalanceDelta delta = manager.swap(key, SwapParams(zeroForOne, amountSpecified, limit), "");
        Settlement.settle(manager, key.currency0, delta.amount0());
        Settlement.settle(manager, key.currency1, delta.amount1());
        return abi.encode(delta);
    }
}

/// @notice Passes a token through the pool manager's flash accounting: pay it in, take it out to someone else.
/// No pool is touched. It exists to show what the pool manager's exemption makes possible.
contract PoolManagerRelay is IUnlockCallback {
    IPoolManager private immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function relay(Currency currency, address to, uint256 amount) external {
        manager.unlock(abi.encode(currency, to, amount));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(manager), "not the pool manager");
        (Currency currency, address to, uint256 amount) = abi.decode(data, (Currency, address, uint256));
        manager.sync(currency);
        ITransfer(Currency.unwrap(currency)).transfer(address(manager), amount);
        manager.settle();
        manager.take(currency, to, amount);
        return "";
    }
}
