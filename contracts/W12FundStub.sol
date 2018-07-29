pragma solidity ^0.4.24;

import "./W12Fund.sol";
import "./WToken.sol";


contract W12FundStub is W12Fund {
    constructor (address crowdsaleAddress, address swapAddress, address wTokenAddress) public {
        crowdsale = IW12Crowdsale(crowdsaleAddress);
        swap = swapAddress;
        wToken = WToken(wTokenAddress);
    }

    function _receiveFunds(uint amount) external nonReentrant {
        require(address(this).balance >= amount);

        msg.sender.transfer(amount);
    }

    function _setTotalFunded(uint amount) external {
        totalFunded = amount;
    }

    function _setTotalRefunded(uint amount) external {
        totalRefunded = amount;
    }

    function() payable external {}

    // allow any sender
    modifier onlyFrom(address sender) {
        _;
    }
}