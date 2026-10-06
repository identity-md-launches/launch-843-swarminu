// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SwarmInu} from "../../src/SwarmInu.sol";

/// @notice Stands in for the launch factory: deploys the token (so it receives the supply), answers
/// `distributorOf` and moves tokens the way the factory does.
contract MockProjectFactory {
    mapping(uint64 => address) public distributorOf;

    function deployToken(address poolManager, uint64 launchNumber) external returns (SwarmInu) {
        return new SwarmInu(address(this), poolManager, launchNumber);
    }

    function setDistributor(uint64 launchNumber, address distributor) external {
        distributorOf[launchNumber] = distributor;
    }

    function move(SwarmInu token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }

    function pull(SwarmInu token, address from, address to, uint256 amount) external returns (bool) {
        return token.transferFrom(from, to, amount);
    }
}

/// @notice A factory whose `distributorOf` always reverts.
contract RevertingFactory {
    function distributorOf(uint64) external pure returns (address) {
        revert("no distributor");
    }
}

/// @notice A factory whose `distributorOf` spends every unit of gas it is given.
contract GasBurningFactory {
    function distributorOf(uint64) external pure returns (address) {
        while (true) {}
        return address(0);
    }
}

/// @notice A factory that answers with fewer than 32 bytes.
contract ShortAnswerFactory {
    fallback() external {
        assembly {
            mstore(0x00, 0xffffffff)
            return(0x1c, 0x04)
        }
    }
}

/// @notice A factory that answers with a word that is not a clean address.
contract DirtyAnswerFactory {
    address public immutable target;

    constructor(address target_) {
        target = target_;
    }

    fallback() external {
        uint256 word = uint256(uint160(target)) | (1 << 160);
        assembly {
            mstore(0x00, word)
            return(0x00, 0x20)
        }
    }
}

/// @notice A factory that answers with far more data than a word; the first word names `target`.
contract OversizedAnswerFactory {
    address public immutable target;

    constructor(address target_) {
        target = target_;
    }

    fallback() external {
        address target_ = target;
        assembly {
            mstore(0x00, target_)
            return(0x00, 0x2000)
        }
    }
}
