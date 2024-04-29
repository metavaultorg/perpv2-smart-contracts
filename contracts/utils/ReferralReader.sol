// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.17;

import "../interfaces/IReferralStorage.sol";

/// @title ReferralReader
/// @notice For getting bulk code owners
contract ReferralReader {
    function getCodeOwners(IReferralStorage _referralStorage, bytes32[] memory _codes) external view returns (address[] memory) {
        address[] memory owners = new address[](_codes.length);

        for (uint256 i; i < _codes.length; i++) {
            bytes32 code = _codes[i];
            owners[i] = _referralStorage.codeOwners(code);
        }

        return owners;
    }
}
