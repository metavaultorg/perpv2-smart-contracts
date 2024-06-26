// SPDX-License-Identifier: BSD-3-Clause

pragma solidity 0.8.22;

interface IReferencePriceFeed {
    function getPrice(address _feed) external view returns (uint256);
}
