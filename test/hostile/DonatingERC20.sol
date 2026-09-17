// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
// SPDX-License-Identifier: LicenseRef-DCL-1.0
pragma solidity =0.8.25;

/// @dev Minimal ERC20 that over-delivers on `transfer` into one beneficiary:
/// moves `amount` and mints `bonus` extra to the recipient. Models any token
/// whose transfers can deliver more than requested (rebasing up, reward-bearing,
/// airdropping) so "forward everything received" is observable.
contract DonatingERC20 {
    string public constant name = "Donor";
    string public constant symbol = "DONR";
    uint8 public constant decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public beneficiary;
    uint256 public bonus;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function setDonation(address beneficiary_, uint256 bonus_) external {
        beneficiary = beneficiary_;
        bonus = bonus_;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        if (to == beneficiary && bonus > 0) {
            balanceOf[to] += bonus;
            totalSupply += bonus;
            bonus = 0;
        }
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}
