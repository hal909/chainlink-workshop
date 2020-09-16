// SPDX-License-Identifier: MIT
pragma solidity 0.6.10;

import {ERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AggregatorV3Interface} from "./AggregatorV3Interface.sol";
import {ILendingPool} from "./ILendingPool.sol";
import {SafeMath} from "@openzeppelin/contracts/math/SafeMath.sol";

/**
 * LendingPool Contract for Chainlink workshop 
 * Assumptions & Constraints:
 * - TUSD is always worth $1
 * - Ignore Leap Years
 * - Fixed interest rate on borrowing
 * - Can't withdraw if pool lacks liquidity
 * - No reserve
 */
abstract contract LendingPool is ILendingPool, ERC20 {
    using SafeMath for uint256;

    /* contracts */
    
    IERC20 tusd; // tusd stablecoin
    IERC20 link; // chainlink coin
    AggregatorV3Interface internal linkPriceFeed; // chainlink aggregator
    
    /* variables */
    
    uint256 rate;           // interest rate
    uint256 ratio;          // collateralization ratio
    uint256 index;          // tracks interest owed by borrowers
    uint256 linkPrice;      // last price of ETH
    uint256 totalBorrow;    // total TUSD borrowed
    uint256 totalCollateral;// total LINK collateral
    uint256 lastUpdated;    // time last updated
    
    /* constants */
    
    // minimal interval to update interest earned
    uint256 constant INTERVAL = 1 minutes;
    // total intervals ignoring leap years
    uint256 constant TOTAL_INTERVALS = 525600;  
    
    /* structures */
    
    // tuple to represent borrow checkpoint
    // this is used to calculate how much interest an account owes
    struct Checkpoint {
        uint256 balance;
        uint256 index;
    }

    struct User {
        // TUSD amount borrowed
        uint256 borrow;
        // ETH collateral amount
        uint256 collateral;
        // stores last updated balance & index
        Checkpoint checkpoint;
    }
    
    /* mappings */
    
    // store users of this smart contract
    mapping(address => User) users;

    // ropsten testnet
    constructor() public {
        tusd = IERC20(0xB36938c51c4f67e5E1112eb11916ed70A772bD75);
        link = IERC20(0x20fE562d797A42Dcb3399062AE9546cd06f63280);
        linkPriceFeed = AggregatorV3Interface(0x40c9885aa8213B40e3E8a0a9aaE69d4fb5915a3A);
        totalBorrow = 0;
        totalCollateral = 0;
        rate = 100000000000000000;      // 0.1
        ratio = 15000000000000000000;   // 1.5
    }

    // get TUSD balance of this contract
    function balance() public override view returns (uint256) {
        return tusd.balanceOf(address(this));
    }

    // get price of interest bearing token
    function exchangeRate() public override view returns (uint256) {
        // exchange rate = (TUSD balance + total borrowed) / supply
        totalBorrow.add(balance()).div(totalSupply());
    }

    // mint interest bearing TUSD
    // @param amount TUSD amount
    function mint(uint256 amount) public override {
        require(tusd.transferFrom(msg.sender, address(this), amount), "insufficient TUSD");
        uint256 value = amount.div(exchangeRate());
        // amount of tokens based on total interest earned by pool
        _mint(msg.sender, value);
    }

    // redeem pool tokens for TUSD
    // @param amount zToken amonut
    function redeem(uint256 amount) public override {
        require(balanceOf(msg.sender) >= amount, "not enough balance");
        require(balance().sub(amount) >= totalBorrow, "pool lacks liquidity");
        // calculate underlying value of pool tokens
        uint256 value = amount.mul(exchangeRate());
        // burn pool tokens
        _burn(msg.sender, amount);
        // transfer TUSD to sender
        tusd.transfer(msg.sender, value);
    }

    // deposit LINK to use as collateral to borrow
    function deposit(uint256 amount) public override {
        require(link.transferFrom(msg.sender, address(this), amount), "insufficient LINK");
        User storage user = users[msg.sender];
        user.collateral.add(amount);
        totalCollateral.add(amount);
    }

    // withdraw LINK used as collateral
    // could cause user to be undercollateralized
    function withdraw(uint256 amount) public override {
        User storage user = users[msg.sender];
        require(user.collateral >= amount, "insufficient collateral");
        totalCollateral.sub(amount);
        user.collateral.sub(amount);
    }

    // borrow TUSD using LINK as collateral
    function borrow(uint256 amount) public override {
        User storage user = users[msg.sender];
        require(amount >= balance(), "not enough liquidity to borrow");
        require(calculateRatio(user.borrow.add(amount), user.collateral) > ratio, "too much borrow");
        _updateAccount(msg.sender);
    }

    // repay TUSD debt
    function repay(uint256 amount) public override {
        User storage user = users[msg.sender];
        require(user.borrow <= amount, "cannot repay more than borrowed");
        require(tusd.transferFrom(msg.sender, address(this), amount), "insufficient TUSD to repay");
        user.borrow = user.borrow.sub(amount);
        _updateAccount(msg.sender);
    }

    function _debt(address account) internal view returns (uint256) {
        User storage user = users[account];
    }

    // public view to see amount owed
    function debt(address account) public view returns (uint256) {
        User storage user = users[msg.sender];
        return _debt(account);
    }

    function _updateAccount(address account) internal override {
        // TODO
    }

    // update oracle prices and total interest earned
    function update() public override {
        // only update if at least one interval has passed
        if (lastUpdated.add(INTERVAL) <= block.timestamp) {
            // calculate time passed
            uint256 passed = block.timestamp.sub(lastUpdated);
            // calculate intervals passed since last update
            uint256 time = passed.div(INTERVAL);

            // calculate period interest = 1 + r * t
            uint256 period = rate.mul(
                time.div(TOTAL_INTERVALS)
                .mul(rate)
                .add(1)
            );
            // update to current timestamp
            lastUpdated = block.timestamp;

            // update index
            index = index.mul(period);

            // update total borrow
            totalBorrow = totalBorrow.mul(period);

            updatePrice();
        }
    }

    // liquidate account ETH if below threshold
    function liquidate(address account, uint256 amount) public override {
        update();
        User memory user = users[account];
        require(user.borrow !=0, "account has not borrowed");
        require(calculateRatio(user.borrow, user.collateral) < ratio, "account not undercollateralized");
        require(amount <= user.collateral, "amount too high to liquidate");
    }

    // fetch eth price from chainlink
    function fetchlinkPrice() public view returns (int256) {
        (
            uint80 roundID, 
            int price,
            uint startedAt,
            uint timeStamp,
            uint80 answeredInRound
        ) = linkPriceFeed.latestRoundData();
        // If the round is not complete yet, timestamp is 0
        require(timeStamp > 0, "Round not complete");
        return price;
    }

    function updatePrice() public {
        // cast to uint256 * add 10 decimals of precision
        linkPrice = uint256(fetchlinkPrice()).mul(10**10);
    }

    // calculate collateralization ratio
    function calculateRatio(uint256 borrow, uint256 collateral) public returns (uint256) {
        return borrow.div(collateral.mul(linkPrice));
    }
}