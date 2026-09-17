// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
// SPDX-License-Identifier: LicenseRef-DCL-1.0
pragma solidity =0.8.25;

/// @dev Minimal ERC20 whose transfer hooks attempt ONE re-entrant call into a
/// target and record the outcome. Deposited into a REAL Raindex vault, so the
/// full inventory→Raindex→token call chain is live; only the token is hostile.
contract ReentrantERC20 {
    string public constant name = "Evil";
    string public constant symbol = "EVIL";
    uint8 public constant decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public target;
    bytes public reentryCalldata;
    bool public armed;
    uint256 public skipHooks;
    bool internal inFlight;
    bool public reentrySucceeded;
    bytes4 public reentryRevertSelector;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    /// @param skipHooks_ Number of transfer hooks to let pass before firing,
    /// to choose WHERE in the call chain the re-entry happens.
    function arm(address target_, bytes calldata reentryCalldata_, uint256 skipHooks_) external {
        target = target_;
        reentryCalldata = reentryCalldata_;
        skipHooks = skipHooks_;
        armed = true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        _hook();
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _move(from, to, amount);
        _hook();
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }

    function _hook() internal {
        if (armed && !inFlight) {
            if (skipHooks > 0) {
                skipHooks--;
                return;
            }
            inFlight = true;
            armed = false;
            //slither-disable-next-line low-level-calls
            (bool ok, bytes memory ret) = target.call(reentryCalldata);
            reentrySucceeded = ok;
            if (!ok && ret.length >= 4) reentryRevertSelector = bytes4(ret);
            inFlight = false;
        }
    }
}
