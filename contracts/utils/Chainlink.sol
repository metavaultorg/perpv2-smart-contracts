// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.17;

import '@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol';
import "./interfaces/IReferencePriceFeed.sol";

/// @title Chainlink
/// @notice Consumes price data
contract Chainlink is IReferencePriceFeed{
    // -- Constants -- //
    uint256 public constant UNIT = 10 ** 18;
    uint256 public constant RATE_STALE_PERIOD = 86400;

    // -- Errors -- //
    error StaleRate();

    /// @notice Returns the latest chainlink price
    /// @param _feed address of chainlink pricefeed
    function getPrice(address _feed) public override view returns (uint256) {
        if (_feed == address(0)) return 0;

        AggregatorV3Interface priceFeed = AggregatorV3Interface(_feed);

        (
            uint80 roundId, 
            int price, 
            /*uint startedAt*/,
            uint256 updatedAt, 
            uint80 answeredInRound
        ) = priceFeed.latestRoundData();
        require(price > 0, "Chainlink price <= 0");
        require(updatedAt != 0, "Incomplete round");
        require(answeredInRound >= roundId, "Stale price");

        if (updatedAt < block.timestamp - RATE_STALE_PERIOD) {
            revert StaleRate();
        }

        uint8 decimals = priceFeed.decimals();

        // Return 18 decimals standard
        return (uint256(price) * UNIT) / 10 ** decimals;
    }
}
