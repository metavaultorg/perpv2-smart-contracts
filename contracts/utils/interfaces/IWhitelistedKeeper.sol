// SPDX-License-Identifier: BSD-3-Clause

pragma solidity 0.8.17;

interface IWhitelistedKeeper {
    function setWhitelistedKeeper(address keeper, bool isActive) external;
}
