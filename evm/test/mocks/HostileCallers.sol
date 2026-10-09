// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OutboundRequest} from "../../src/TraiectaTypes.sol";
import {IHyperionRouter} from "../../src/interfaces/ITraiectaRouter.sol";

/// @title A sender who cannot be paid back
/// @notice No receive, no fallback, so the refund at the end of `bridgeOut` has nowhere to go.
/// @dev The router refuses the whole transfer rather than keeping the change. Silently pocketing
/// it would be a second fee nobody agreed to, and the amount would move with a gas market the
/// sender never looked at.
contract RefundRefuser {
    function bridge(address router, OutboundRequest calldata request, uint256 value)
        external
        payable
        returns (uint64)
    {
        return IHyperionRouter(router).bridgeOut{value: value}(request);
    }

    function approve(address token, address spender, uint256 amount) external {
        // Low level so this mock does not have to import an ERC20 interface it otherwise ignores.
        (bool ok,) = token.call(abi.encodeWithSignature("approve(address,uint256)", spender, amount));
        require(ok, "approve");
    }
}

/// @title A token that calls back in mid transfer
/// @notice Re-enters `bridgeOut` from inside `transferFrom`.
/// @dev Tokens are admin registered, so a deliberately hostile one is not the threat this guards
/// against. A token with a transfer hook that happens to call back into a contract holding its
/// balance is, and the guard either holds for both or for neither, so it is worth a test.
contract ReenteringToken {
    string public name = "Reentering Token";
    string public symbol = "REENT";
    uint8 public decimals = 6;

    mapping(address holder => uint256 balance) public balanceOf;
    mapping(address holder => mapping(address spender => uint256 amount)) public allowance;

    address public router;
    OutboundRequest private _replay;
    bool public armed;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function arm(address router_, OutboundRequest calldata replay) external {
        router = router_;
        _replay = replay;
        armed = true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (armed) {
            armed = false;
            IHyperionRouter(router).bridgeOut(_replay);
        }
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) private {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// @title A router wired to something that cannot take its change back
/// @notice No receive, no fallback, so anything an adapter tries to hand back bounces.
/// @dev The real router has a `receive`, which makes this a stand in for a deployment pointed at
/// the wrong address rather than for anything that should ever exist. What it pins down is the
/// adapter's choice to revert instead of shrugging: native currency stranded in an adapter is
/// native currency nobody has written a function to get out again.
contract DeafRouter {}
