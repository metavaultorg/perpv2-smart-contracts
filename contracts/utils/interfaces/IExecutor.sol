//SPDX-License-Identifier: BSD-3-Clause

pragma solidity 0.8.17;

interface IExecutor {
    function setLiquidationFee(uint256 bps) external;   
}
