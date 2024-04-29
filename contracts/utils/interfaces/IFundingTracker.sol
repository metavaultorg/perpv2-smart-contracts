//SPDX-License-Identifier: BSD-3-Clause

pragma solidity 0.8.17;

interface IFundingTracker {
    function setFundingInterval(uint256 interval) external;
}