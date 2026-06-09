// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Minimal Uniswap V2 router stub for local testing. It only needs to
/// expose `WETH()` and accept an `addLiquidityETH` call (pulling the tokens and
/// keeping the ETH) so the migration path can be exercised end to end.
contract MockUniswapV2Router {
    address public immutable weth;

    uint256 public lastAmountToken;
    uint256 public lastAmountETH;
    address public lastTo;

    constructor(address _weth) {
        weth = _weth;
    }

    function WETH() external view returns (address) {
        return weth;
    }

    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint /* amountTokenMin */,
        uint /* amountETHMin */,
        address to,
        uint /* deadline */
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity) {
        require(
            IERC20(token).transferFrom(
                msg.sender,
                address(this),
                amountTokenDesired
            ),
            "transferFrom failed"
        );
        lastAmountToken = amountTokenDesired;
        lastAmountETH = msg.value;
        lastTo = to;
        return (amountTokenDesired, msg.value, msg.value);
    }
}
