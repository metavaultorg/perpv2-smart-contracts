//SPDX-License-Identifier: BSD-3-Clause

pragma solidity 0.8.22;

interface IChainlink {
    function setPriceFeedStalePeriod(address _feed, uint256 _stalePeriod) external;
}
