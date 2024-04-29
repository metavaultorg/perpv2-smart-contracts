//SPDX-License-Identifier: BSD-3-Clause

pragma solidity 0.8.17;

interface IOrderBook {    
    function setAreNewOrdersPaused(bool b) external;
    function setIsProcessingPaused(bool b) external;
    function setMaxMarketOrderTTL(uint256 amount) external;
    function setMaxTriggerOrderTTL(uint256 amount) external;
    function setOrderExecutionFee(uint256 amount) external;
    function setEthSingedMessageHash(bytes32 _messageHash) external;
    function enableOrderByGov(address _account) external;

}
