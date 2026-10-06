// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice The one read SwarmInu makes on the launch factory.
interface IProjectFactory {
    function distributorOf(uint64 launchNumber) external view returns (address);
}

/// @title SwarmInu (SI)
/// @notice Fixed-supply ERC-20 with a 2% transfer fee paid to a fixed recipient.
/// @dev The whole supply is minted once, to the deployer, in the constructor; there is no mint, burn, owner, pause
/// or blacklist afterwards. The fee is skipped for the launch flows that must move exact amounts: anything the
/// factory moves, anything into or out of the Uniswap v4 PoolManager, and anything into or out of the launch's
/// MerkleDistributor. Every other transfer pays the fee.
contract SwarmInu is ERC20 {
    /// @notice 1,000,000,000 SI with 18 decimals.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;

    /// @notice The transfer fee in basis points (2%).
    uint256 public constant FEE_BPS = 200;

    uint256 private constant BPS_DENOMINATOR = 10_000;

    /// @notice The wallet every fee is paid to. It cannot be changed.
    address public constant FEE_RECIPIENT = 0x66522f25035C3FAFd2c6D950a506FDa457E06344;

    /// @notice Gas forwarded to the factory's `distributorOf` read. A read that needs more is treated as unanswered,
    /// so a misbehaving factory can make a transfer dearer but can never make it revert.
    uint256 public constant DISTRIBUTOR_LOOKUP_GAS = 100_000;

    /// @notice The launch factory. Exempt as caller, sender and recipient.
    address public immutable factory;

    /// @notice The Uniswap v4 PoolManager. Exempt as sender and recipient, so pool flows settle exactly.
    address public immutable poolManager;

    /// @notice The launch this token belongs to; the key of its distributor on the factory.
    uint64 public immutable launchNumber;

    error ZeroAddress();

    constructor(address factory_, address poolManager_, uint64 launchNumber_) ERC20("SwarmInu", "SI") {
        if (factory_ == address(0) || poolManager_ == address(0)) revert ZeroAddress();
        factory = factory_;
        poolManager = poolManager_;
        launchNumber = launchNumber_;
        _mint(msg.sender, TOTAL_SUPPLY);
    }

    /// @notice The launch's MerkleDistributor as the factory reports it now, or the zero address when the factory
    /// has not set one or does not answer.
    function distributor() public view returns (address distributor_) {
        address factory_ = factory;
        bytes memory data = abi.encodeCall(IProjectFactory.distributorOf, (launchNumber));
        uint256 gasCap = DISTRIBUTOR_LOOKUP_GAS;
        uint256 word = 0;
        // Copies at most one word of return data, so the factory cannot hand back a memory bomb.
        assembly ("memory-safe") {
            let ok := staticcall(gasCap, factory_, add(data, 0x20), mload(data), 0x00, 0x20)
            if and(ok, gt(returndatasize(), 0x1f)) { word := mload(0x00) }
        }
        // casting to 'uint160' is safe because the word is checked to fit first
        // forge-lint: disable-next-line(unsafe-typecast)
        if (word <= type(uint160).max) distributor_ = address(uint160(word));
    }

    /// @notice Whether a transfer of `from`'s tokens to `to`, submitted by `operator`, skips the fee.
    function isFeeExempt(address operator, address from, address to) public view returns (bool) {
        if (operator == factory || from == factory || to == factory) return true;
        if (from == poolManager || to == poolManager) return true;
        // The recipient paying itself a fee would only add a second event.
        if (from == FEE_RECIPIENT || to == FEE_RECIPIENT) return true;
        address distributor_ = distributor();
        return distributor_ != address(0) && (from == distributor_ || to == distributor_);
    }

    /// @notice The fee an ordinary (non-exempt) transfer of `value` pays, rounded down.
    function feeOn(uint256 value) public pure returns (uint256) {
        return (value * FEE_BPS) / BPS_DENOMINATOR;
    }

    /// @dev The sender is always debited exactly `value`; a non-exempt transfer credits `feeOn(value)` to the
    /// recipient of the fee and the rest to `to`. The mint in the constructor is the only transfer from zero.
    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0) || isFeeExempt(_msgSender(), from, to)) {
            super._update(from, to, value);
            return;
        }
        // Checked here so the error reports the whole amount rather than whichever leg ran short.
        uint256 balance = balanceOf(from);
        if (balance < value) revert ERC20InsufficientBalance(from, balance, value);
        uint256 fee = feeOn(value);
        if (fee != 0) super._update(from, FEE_RECIPIENT, fee);
        super._update(from, to, value - fee);
    }
}
