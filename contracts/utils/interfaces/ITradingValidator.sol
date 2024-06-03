//SPDX-License-Identifier: BSD-3-Clause

pragma solidity 0.8.22;

interface ITradingValidator {
    function setMaxOI(bytes10 market, address asset, uint256 amount) external;
    function setPoolHourlyDecay(uint256 bps) external;
    function setPoolProfitLimit(address asset, uint256 bps) external;
}
