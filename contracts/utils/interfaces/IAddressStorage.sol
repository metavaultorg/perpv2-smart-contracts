//SPDX-License-Identifier: BSD-3-Clause

pragma solidity 0.8.17;

interface IAddressStorage {
    function setAddress(string calldata key, address value, bool overwrite) external returns (bool) ;
}
