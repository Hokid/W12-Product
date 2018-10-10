pragma solidity ^0.4.24;

import "openzeppelin-solidity/contracts/ownership/Ownable.sol";
import "openzeppelin-solidity/contracts/ReentrancyGuard.sol";
import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "openzeppelin-solidity/contracts/token/ERC20/ERC20.sol";
import "./IW12Crowdsale.sol";
import "./IW12Fund.sol";
import "../rates/IRates.sol";
import "../libs/Percent.sol";
import "../libs/FundAccount.sol";
import "../versioning/Versionable.sol";
import "../token/IWToken.sol";

contract W12Fund is Versionable, IW12Fund, Ownable, ReentrancyGuard {
    using SafeMath for uint;
    using Percent for uint;
    using FundAccount for FundAccount.Account;

    bytes32 constant METHOD_ETH = bytes32('ETH');
    bytes32 constant METHOD_USD = bytes32('USD');

    IW12Crowdsale public crowdsale;
    IWToken public wToken;
    IRates public rates;
    address public swap;
    address public serviceWallet;
    // fee for realised tranche
    uint public trancheFeePercent;
    // total percent of realised project tranche
    uint public totalTranchePercentReleased;
    // maps of completed tranches periods
    mapping (uint => bool) completedTranches;

    // total funded assets
    FundAccount.Account totalFunded;
    // total realised funded assets bt currency symbol
    // updated when tranche was realised or investor assets was refunded
    mapping(bytes32 => uint) totalFundedRealised;
    // total amount of bought token
    uint public totalTokenBought;
    // total amount of refunded token
    uint public totalTokenRefunded;
    // total amount of bought token per investor
    mapping (address => uint) tokenBoughtPerInvestor;
    // total funded assets of each investor
    mapping (address => FundAccount.Account) fundedPerInvestor;

    event FundsReceived(address indexed investor, uint tokenAmount, bytes32 symbol, uint cost);
    event FundsRefunded(address indexed buyer, uint weiAmount, uint tokenAmount);
    event TrancheTransferred(address indexed receiver, bytes32 symbol, uint amount);
    event TrancheReleased(address indexed receiver, uint percent);

    constructor(uint version, uint _trancheFeePercent, IRates _rates) Versionable(version) public {
        require(_trancheFeePercent.isPercent() && _trancheFeePercent.fromPercent() < 100);
        require(_rates != address(0));

        trancheFeePercent = _trancheFeePercent;
        rates = _rates;
    }

    function setCrowdsale(IW12Crowdsale _crowdsale) onlyOwner external {
        require(_crowdsale != address(0));
        require(_crowdsale.getWToken() != address(0));

        crowdsale = _crowdsale;
        wToken = IWToken(_crowdsale.getWToken());
    }

    function setSwap(address _swap) onlyOwner external {
        require(_swap != address(0));

        swap = _swap;
    }

    function setServiceWallet(address _serviceWallet) onlyOwner external {
        require(_serviceWallet != address(0));

        serviceWallet = _serviceWallet;
    }

    /**
     * @dev Record purchase result to the fund and check the fund balance
     * @param investor An investor address
     * @param tokenAmount Token amount that was bought
     * @param symbol Symbol of payment method
     * @param cost Cost of token amount
     * @param costUSD Cost in USD
     */
    function recordPurchase(
        address investor,
        uint tokenAmount,
        bytes32 symbol,
        uint cost,
        uint costUSD
    )
        external payable onlyFrom(crowdsale)
    {
        require(tokenAmount > 0);
        require(cost > 0);
        require(costUSD > 0);
        require(investor != address(0));
        require(rates.hasSymbol(symbol));

        // check payment
        if (symbol == METHOD_ETH)  {
            require(msg.value >= cost);
        } else {
            require(rates.isToken(symbol));
            require(ERC20(rates.getTokenAddress(symbol)).balanceOf(address(this)) >= totalFunded.amountOf(symbol).add(cost));
        }

        // write to investor account
        tokenBoughtPerInvestor[investor] = tokenBoughtPerInvestor[investor].add(tokenAmount);
        fundedPerInvestor[investor].deposit(symbol, cost);
        fundedPerInvestor[investor].deposit(METHOD_USD, costUSD);

        // write to total fund
        totalTokenBought = totalTokenBought.add(tokenAmount);
        totalFunded.deposit(symbol, cost);
        totalFunded.deposit(METHOD_USD, costUSD);

        emit FundsReceived(investor, tokenAmount, symbol, cost);
    }

    function getInvestorFundedAmount(address _investor, bytes32 _symbol) public view returns(uint) {
        return fundedPerInvestor[_investor].amountOf(_symbol);
    }

    function getInvestorFundedAssetsSymbols(address _investor) public view returns(bytes32[]) {
        return fundedPerInvestor[_investor].symbolsList();
    }

    function getInvestorTokenBoughtAmount(address _investor) public view returns (uint) {
        return tokenBoughtPerInvestor[_investor];
    }

    function getTotalFundedAmount(bytes32 _symbol) public view returns (uint) {
        return totalFunded.amountOf(_symbol);
    }

    function getTotalFundedAssetsSymbols() public view returns (bytes32[]) {
        return totalFunded.symbolsList();
    }

    /**
        a = address(this).balance
        b = totalFunded
        c = buyers[buyer].totalFunded
        d = buyers[buyer].totalBought
        e = wtokensToRefund

        ( ( c * (a / b) ) / d ) * e = (refund amount)
    */
//    function getRefundAmount(uint wtokensToRefund) public view returns (uint result) {
//        uint exp = tokenDecimals < tokenDecimals.add(8) ? tokenDecimals.add(8) : tokenDecimals;
//
//        require(uint(- 1) / 10 >= exp);
//
//        uint max = uint(-1) / 10 ** exp;
//        address buyer = msg.sender;
//
//        if(wtokensToRefund == 0
//            || buyers[buyer].totalBought == 0
//            || address(this).balance == 0
//            || wToken.balanceOf(buyer) < wtokensToRefund
//            || buyers[buyer].totalBought < wtokensToRefund
//        ) return;
//
//        uint allowedFund = buyers[buyer].totalFunded.mul(totalFunded).div(address(this).balance);
//        uint precisionComponent = allowedFund >= max ? 1 : 10 ** exp;
//
//        result = allowedFund
//            .mul(precisionComponent)
//            .div(buyers[buyer].totalBought)
//            .mul(wtokensToRefund)
//            .div(precisionComponent);
//    }

    /**
     * @notice Get tranche invoice
     * @return uint[3] result:
     * [tranchePercent, totalTranchePercentBefore, milestoneIndex]
     */
    function getTrancheInvoice() public view returns (uint[3] result) {
        if (!trancheTransferAllowed()) return;

        (uint index, bool found) = crowdsale.getCurrentMilestoneIndex();

        if (!found) return;

        (uint lastIndex, ) = crowdsale.getLastMilestoneIndex();
        (,,, uint32 lastWithdrawalWindow,,) = crowdsale.getMilestone(lastIndex);

        // get percent from prev milestone
        index = index == 0 || now >= lastWithdrawalWindow ? index : index - 1;

        ( , uint tranchePercent, , uint32 withdrawalWindow, , ) = crowdsale.getMilestone(index);

        bool completed = completedTranches[index];

        if (completed) return;

        uint prevIndex = index;
        uint totalTranchePercentBefore;

        while (prevIndex > 0) {
            prevIndex--;

            (, uint _tranchePercent, , , , ) = crowdsale.getMilestone(prevIndex);

            totalTranchePercentBefore = totalTranchePercentBefore.add(_tranchePercent);
        }

        result[0] = tranchePercent
            .add(totalTranchePercentBefore)
            .sub(totalTranchePercentReleased);
        result[1] = totalTranchePercentBefore;
        result[2] = index;
    }

    /**
     * @notice Realise project tranche
     */
    function tranche() external onlyOwner nonReentrant {
        require(trancheTransferAllowed());

        uint[3] memory trancheInvoice = getTrancheInvoice();

        require(trancheInvoice[0] > 0);
        require(totalFunded.symbolsList().length != 0);

        completedTranches[trancheInvoice[2]] = true;
        totalTranchePercentReleased = totalTranchePercentReleased.add(trancheInvoice[0]);

        _transferTranche(trancheInvoice);

        emit TrancheReleased(msg.sender, trancheInvoice[0]);
    }

    function _transferTranche(uint[3] _invoice) internal {
        uint ln = totalFunded.symbolsList().length;

        while(ln != 0) {
            bytes32 symbol = totalFunded.symbolsList()[--ln];
            uint amount = totalFunded.amountOf(symbol);

            if (amount == 0) continue;

            amount = amount.savePercent(_invoice[0]);

            require(amount > 0);

            totalFundedRealised[symbol] = totalFundedRealised[symbol].add(amount);

            if (symbol == METHOD_USD)  continue;

            if (symbol != METHOD_ETH) {
                require(rates.isToken(symbol));
                require(ERC20(rates.getTokenAddress(symbol)).balanceOf(address(this)) >= amount);
            }

            uint fee = trancheFeePercent > 0
                ? amount.savePercent(trancheFeePercent)
                : 0;

            if (trancheFeePercent > 0) require(fee > 0);

            if (symbol == METHOD_ETH) {
                if (fee > 0) serviceWallet.transfer(fee);
                msg.sender.transfer(amount.sub(fee));
            } else {
                if (fee > 0) ERC20(rates.getTokenAddress(symbol)).transfer(serviceWallet, fee);
                ERC20(rates.getTokenAddress(symbol)).transfer(msg.sender, amount.sub(fee));
            }

            emit TrancheTransferred(msg.sender, symbol, amount);
        }
    }

//    function refund(uint wtokensToRefund) external nonReentrant {
//        address buyer = msg.sender;
//
//        require(refundAllowed());
//        require(wtokensToRefund > 0);
//        require(buyers[buyer].totalBought >= wtokensToRefund);
//        require(wToken.balanceOf(buyer) >= wtokensToRefund);
//        require(wToken.allowance(msg.sender, address(this)) >= wtokensToRefund);
//
//        uint transferAmount = getRefundAmount(wtokensToRefund);
//
//        require(transferAmount > 0);
//
//        buyers[buyer].totalBought = buyers[buyer].totalBought
//            .sub(wtokensToRefund);
//        buyers[buyer].totalFunded = buyers[buyer].totalFunded
//            .sub(wtokensToRefund.mul(buyers[buyer].averagePrice).div(10 ** tokenDecimals));
//
//        // update total refunded amount counter
//        totalRefunded = totalRefunded.add(transferAmount);
//
//        require(wToken.transferFrom(buyer, swap, wtokensToRefund));
//        buyer.transfer(transferAmount);
//
//        emit FundsRefunded(buyer, transferAmount, wtokensToRefund);
//    }
//
//    function refundAllowed() public view returns (bool) {
//        (uint index, bool found) = crowdsale.getCurrentMilestoneIndex();
//
//        // first milestone is reserved for the project to claim initial amount of payments. No refund allowed at this stage.
//        if(index == 0) return;
//
//        (uint32 endDate, , , uint32 withdrawalWindow, , ) = crowdsale.getMilestone(index);
//
//        return endDate <= now && now < withdrawalWindow;
//    }

    function trancheTransferAllowed() public view returns (bool) {
        (uint index, bool found) = crowdsale.getCurrentMilestoneIndex();
        (uint lastIndex, ) = crowdsale.getLastMilestoneIndex();

        if(!found) return;
        if(index == 0) return true;

        (uint32 endDate, , , , , ) = crowdsale.getMilestone(index);
        (, , ,uint32 lastWithdrawalWindow, , ) = crowdsale.getMilestone(lastIndex);

        return endDate > now || lastWithdrawalWindow <= now;
    }

    modifier onlyFrom(address sender) {
        require(msg.sender == sender);

        _;
    }
}