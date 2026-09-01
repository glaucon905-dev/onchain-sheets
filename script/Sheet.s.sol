// SPDX-License-Identifier: ISC
pragma solidity ^0.8.20;

import "frax-std/BaseScript.sol";
import { console } from "frax-std/FraxTest.sol";
import { Sheet } from "src/Sheet.sol";

contract DeployContract is BaseScript {
    function run() public broadcaster {
        _deploy(msg.sender);
    }
}

function _deploy(address owner) {
    address instance = address(new Sheet(256, 256, owner));
    console.log("Sheet deployed @", instance);
}
