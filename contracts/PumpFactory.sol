// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IUniswapV2Router02 {
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    )
        external
        payable
        returns (uint amountToken, uint amountETH, uint liquidity);

    function WETH() external view returns (address);
}

/// @notice Minimal bonding-curve token. Supply is controlled entirely by the
/// factory: minted on buys / at liquidity migration, burned on sells.
contract PumpToken is ERC20 {
    address public immutable factory;

    modifier onlyFactory() {
        require(msg.sender == factory, "Only factory");
        _;
    }

    constructor(
        string memory _name,
        string memory _symbol
    ) ERC20(_name, _symbol) {
        factory = msg.sender;
    }

    function mintFromFactory(address to, uint256 amount) external onlyFactory {
        _mint(to, amount);
    }

    function burnFromFactory(address from, uint256 amount) external onlyFactory {
        _burn(from, amount);
    }
}

contract PumpCloneFactory is Ownable, ReentrancyGuard {
    struct TokenInfo {
        address creator;
        address tokenAddress;
        uint256 vReserveEth;
        uint256 vReserveToken;
        uint256 rReserveEth;
        uint256 rReserveToken;
        bool liquidityMigrated;
    }

    /// @dev Liquidity is permanently locked by sending the LP tokens here.
    address public constant DEAD_ADDRESS =
        0x000000000000000000000000000000000000dEaD;

    /// @dev Fixed final supply of every launched token (curve + LP allocation).
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;

    /// @dev Hard cap on the configurable trade fee (10%).
    uint256 public constant MAX_FEE_BPS = 1000;

    mapping(address => TokenInfo) public tokens;

    address public uniswapRouter;
    address public WETH;

    uint256 public V_ETH_RESERVE;
    uint256 public V_TOKEN_RESERVE;
    uint256 public R_TOKEN_RESERVE;
    uint256 public TRADE_FEE_BPS;
    uint256 public BPS_DENOMINATOR;
    uint256 public LIQUIDITY_MIGRATION_FEE;
    uint256 public totalFee;

    event TokenLaunched(
        address indexed token,
        string name,
        string symbol,
        address indexed creator
    );
    event TokensPurchased(
        address indexed token,
        address indexed buyer,
        uint256 amount,
        uint256 cost
    );
    event TokensSold(
        address indexed token,
        address indexed seller,
        uint256 amount,
        uint256 refund
    );
    event LiquiditySwapped(
        address indexed token,
        uint256 tokenAmount,
        uint256 ethAmount
    );
    event ClaimedFee(uint256 amount);

    constructor(address _router) Ownable(msg.sender) {
        uniswapRouter = _router;
        WETH = IUniswapV2Router02(_router).WETH();

        V_ETH_RESERVE = 15 ether / 1000;
        V_TOKEN_RESERVE = 1073000000 ether;
        R_TOKEN_RESERVE = 793100000 ether;
        TRADE_FEE_BPS = 100; // 1% fee in basis points
        BPS_DENOMINATOR = 10000;
        LIQUIDITY_MIGRATION_FEE = 18 ether / 1000;
    }

    // ---------------------------------------------------------------------
    // Launch
    // ---------------------------------------------------------------------

    function launchToken(
        string memory _name,
        string memory _symbol
    ) external payable nonReentrant {
        require(bytes(_name).length > 0, "Empty name");
        require(bytes(_symbol).length > 0, "Empty symbol");

        PumpToken token = new PumpToken(_name, _symbol);
        TokenInfo storage info = tokens[address(token)];
        info.creator = msg.sender;
        info.tokenAddress = address(token);
        info.vReserveEth = V_ETH_RESERVE;
        info.vReserveToken = V_TOKEN_RESERVE;
        info.rReserveEth = 0;
        info.rReserveToken = R_TOKEN_RESERVE;
        info.liquidityMigrated = false;

        emit TokenLaunched(address(token), _name, _symbol, msg.sender);

        // Optional initial dev buy in the same transaction.
        if (msg.value > 0) {
            _executeBuy(address(token), msg.value, 0, msg.sender);
        }
    }

    // ---------------------------------------------------------------------
    // Trading
    // ---------------------------------------------------------------------

    /// @notice Buy tokens from the bonding curve.
    /// @param minTokensOut Slippage guard: revert if fewer tokens would be minted.
    function buyToken(
        address _token,
        uint256 minTokensOut
    ) external payable nonReentrant {
        require(msg.value > 0, "No ETH sent");
        _executeBuy(_token, msg.value, minTokensOut, msg.sender);
    }

    /// @notice Sell tokens back to the bonding curve.
    /// @param minEthOut Slippage guard: revert if less ETH would be returned.
    function sellToken(
        address _token,
        uint256 tokenAmount,
        uint256 minEthOut
    ) external nonReentrant {
        TokenInfo storage info = tokens[_token];
        require(info.tokenAddress != address(0), "Invalid token");
        require(tokenAmount > 0, "Amount must be greater than 0");
        require(!info.liquidityMigrated, "Trading moved to Uniswap");

        uint256 newReserveToken = info.vReserveToken + tokenAmount;
        uint256 newReserveEth = (info.vReserveEth * info.vReserveToken) /
            newReserveToken;

        uint256 grossEthOut = info.vReserveEth - newReserveEth;
        uint256 fee = (grossEthOut * TRADE_FEE_BPS) / BPS_DENOMINATOR;
        uint256 netEthOut = grossEthOut - fee;

        require(
            grossEthOut > 0 && grossEthOut <= info.rReserveEth,
            "Insufficient ETH in contract"
        );
        require(netEthOut >= minEthOut, "Slippage");

        info.vReserveEth = newReserveEth;
        info.vReserveToken = newReserveToken;
        info.rReserveEth -= grossEthOut;
        info.rReserveToken += tokenAmount;
        totalFee += fee;

        // Burn the sold supply so totalSupply tracks circulating curve supply.
        PumpToken(_token).burnFromFactory(msg.sender, tokenAmount);

        (bool success, ) = payable(msg.sender).call{value: netEthOut}("");
        require(success, "ETH transfer failed");

        emit TokensSold(_token, msg.sender, tokenAmount, netEthOut);
    }

    /// @dev Shared buy logic for both `launchToken` and `buyToken`. Caps the
    /// purchase at the remaining real token reserve, refunds any excess ETH,
    /// and migrates to Uniswap once the curve is exhausted.
    function _executeBuy(
        address _token,
        uint256 ethIn,
        uint256 minTokensOut,
        address buyer
    ) internal {
        TokenInfo storage info = tokens[_token];
        require(info.tokenAddress != address(0), "Invalid token");
        require(!info.liquidityMigrated, "Trading moved to Uniswap");

        uint256 fee = (ethIn * TRADE_FEE_BPS) / BPS_DENOMINATOR;
        uint256 netEthIn = ethIn - fee;

        uint256 newReserveEth = info.vReserveEth + netEthIn;
        uint256 newReserveToken = (info.vReserveEth * info.vReserveToken) /
            newReserveEth;
        uint256 tokensOut = info.vReserveToken - newReserveToken;

        uint256 remaining = info.rReserveToken;
        uint256 refund = 0;

        if (tokensOut >= remaining) {
            // Curve graduates: cap the buy at the remaining real reserve,
            // recompute the exact ETH required, and refund the rest.
            tokensOut = remaining;
            newReserveToken = info.vReserveToken - tokensOut;
            newReserveEth =
                (info.vReserveEth * info.vReserveToken) /
                newReserveToken;
            netEthIn = newReserveEth - info.vReserveEth;

            uint256 totalCost = (netEthIn * BPS_DENOMINATOR) /
                (BPS_DENOMINATOR - TRADE_FEE_BPS);
            fee = totalCost - netEthIn;
            require(ethIn >= totalCost, "Insufficient ETH");
            refund = ethIn - totalCost;
        }

        require(tokensOut > 0, "Zero tokens out");
        require(tokensOut >= minTokensOut, "Slippage");

        info.vReserveEth = newReserveEth;
        info.vReserveToken = newReserveToken;
        info.rReserveEth += netEthIn;
        info.rReserveToken = remaining - tokensOut;
        totalFee += fee;

        PumpToken(_token).mintFromFactory(buyer, tokensOut);
        emit TokensPurchased(_token, buyer, tokensOut, ethIn - refund);

        if (refund > 0) {
            (bool ok, ) = payable(buyer).call{value: refund}("");
            require(ok, "Refund failed");
        }

        if (info.rReserveToken == 0) {
            _migrateLiquidity(_token);
        }
    }

    /// @dev Mints the LP allocation, pairs it with the accumulated ETH (minus
    /// the migration fee) and adds it to Uniswap. LP tokens are burned to lock
    /// liquidity permanently.
    function _migrateLiquidity(address _token) internal {
        TokenInfo storage info = tokens[_token];
        info.liquidityMigrated = true;

        uint256 ethReserve = info.rReserveEth;
        require(
            ethReserve > LIQUIDITY_MIGRATION_FEE,
            "Insufficient ETH for migration"
        );
        uint256 ethForLp = ethReserve - LIQUIDITY_MIGRATION_FEE;
        info.rReserveEth = 0;
        totalFee += LIQUIDITY_MIGRATION_FEE;

        uint256 lpTokens = TOTAL_SUPPLY - PumpToken(_token).totalSupply();
        PumpToken(_token).mintFromFactory(address(this), lpTokens);
        PumpToken(_token).approve(uniswapRouter, lpTokens);

        IUniswapV2Router02(uniswapRouter).addLiquidityETH{value: ethForLp}(
            _token,
            lpTokens,
            0,
            0,
            DEAD_ADDRESS,
            block.timestamp
        );

        emit LiquiditySwapped(_token, lpTokens, ethForLp);
    }

    // ---------------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------------

    function updateReserves(
        uint256 _vEthReserve,
        uint256 _vTokenReserve,
        uint256 _rTokenReserve
    ) external onlyOwner {
        require(_rTokenReserve < TOTAL_SUPPLY, "Reserve exceeds supply");
        V_ETH_RESERVE = _vEthReserve;
        V_TOKEN_RESERVE = _vTokenReserve;
        R_TOKEN_RESERVE = _rTokenReserve;
    }

    function updateFeeRate(uint256 value) external onlyOwner {
        require(value <= MAX_FEE_BPS, "Fee too high");
        TRADE_FEE_BPS = value;
    }

    function updateLiquidityMigrationFee(uint256 value) external onlyOwner {
        LIQUIDITY_MIGRATION_FEE = value;
    }

    function claimFee(address to) external onlyOwner {
        uint256 feeAmount = totalFee;
        totalFee = 0;
        (bool success, ) = payable(to).call{value: feeAmount}("");
        require(success, "Fee transfer failed");
        emit ClaimedFee(feeAmount);
    }

    receive() external payable {}
}
