// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

//  $AIPAD Token
//     _      ___     ____       _      ____
//    / \    |_ _|   |  _ \     / \    |  _ \
//   / _ \    | |    | |_) |   / _ \   | | | |
//  / ___ \   | |    |  __/   / ___ \  | |_| |
// /_/   \_\ |___|   |_|     /_/   \_\ |____/
// =====================================
// - Supply: 1B tokens
// - Tax: 5% tax on aipad traded (shared with the team)
// - Limits: 2% per supply per tx, which is 20M tokens

import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@oz/contracts/access/Ownable.sol";
import "@oz/contracts/token/ERC20/ERC20.sol";
import "@oz/contracts/utils/ReentrancyGuard.sol";

contract AIPAD is ERC20, Ownable, ReentrancyGuard {

    // 1 Million is totalsuppy
    uint256 public constant oneBillion = 1_000_000_000 * 1 ether;
    // precision mitigation value, 100x100
    uint256 public constant hundredPercent = 10_000;
    IUniswapV2Router02 public constant uniswapV2Router = IUniswapV2Router02(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);

    uint256 public sellLimit;
    uint256 public walletBalanceLimit;

    // Taxation
    uint256 public tax;
    // address of the uniswap pair
    address public uniswapV2Pair;

    // team wallet
    address payable public teamWallet;
    address public taxChanger;

    /// @dev Enable trading on Uniswap
    bool public isTradingEnabled;

    // ========== Events ==========
    event TaxChanged(uint256 tax);
    event TradingOnUniSwapEnabled();
    event TradingOnUniSwapDisabled();
    event SwappedToEth(uint256 amount, uint256 ethAmount);
    event Snapshot(uint256 tokenAmount, uint256 ethAmount);
    event ReceivedEther(address indexed from, uint256 amount);
    event TaxActiveChanged(bool isActive);
    event WalletBalanceLimitChanged(uint256 walletBalanceLimit, uint256 sellLimit);
    event TeamWalletUpdated(address teamWallet);
    event AirDropToggled(bool isActive);
    event Taxed(address indexed from, uint256 amountXperp);

    // =========== Errors ==========
    error ZeroAddress();

    // ========== Modifiers ==========
    modifier onlyTaxChanger() {
        require(msg.sender == taxChanger, "Not authorized");
        _;
    }
    // ========== Initialization ==========

    constructor(address payable _teamWallet) Ownable(msg.sender) ReentrancyGuard() ERC20("AI Pad", "AIPAD") {
        if (_teamWallet == address(0)) revert ZeroAddress();
        teamWallet = _teamWallet;
        taxChanger = msg.sender;
        tax = 500;
        walletBalanceLimit = 20_000_000 * 1 ether;
        sellLimit = 20_000_000 * 1 ether;
        _mint(msg.sender, oneBillion);
    }

    function initPair() public {
        uniswapV2Pair = IUniswapV2Factory(uniswapV2Router.factory()).createPair(
            address(this),
            uniswapV2Router.WETH()
        );
        _approve(address(this), address(uniswapV2Router), type(uint256).max);
    }

    // ========== Configuration ==========
    function setTax(uint256 _tax) external onlyTaxChanger {
        require(_tax <= 10000, "Invalid tax");
        tax = _tax;
        emit TaxChanged(_tax);
    }

    /// This function is used to set the wallet balance limit
    /// @param _walletBalanceLimit The new wallet balance limit, maximum allowed amount of tokens in a wallet, transfers are not prohibited
    function setWalletBalanceLimit(uint256 _walletBalanceLimit) external onlyOwner {
        require(_walletBalanceLimit >= 0 && _walletBalanceLimit <= oneBillion, "Invalid wallet balance limit");
        walletBalanceLimit = _walletBalanceLimit;
        emit WalletBalanceLimitChanged(_walletBalanceLimit, sellLimit);
    }

    /// This function is used to set the sell limit
    /// @param _sellLimit The new sell limit, maximum allowed amount of tokens to be sold in a single transaction
    function setSellLimit(uint256 _sellLimit) external onlyOwner {
        require(_sellLimit >= 0 && _sellLimit <= oneBillion, "Invalid sell balance limit");
        sellLimit = _sellLimit;
        emit WalletBalanceLimitChanged(walletBalanceLimit, _sellLimit);
    }

    /// @notice This function is used to set the team wallet
    function updateTeamWallet(address payable _teamWallet) external onlyOwner {
        require(_teamWallet != address(0), "Invalid team wallet");
        teamWallet = _teamWallet;
        emit TeamWalletUpdated(_teamWallet);
    }

    /// @notice This function is used to enable trading on Uniswap
    function EnableTradingOnUniSwap() external onlyOwner {
        isTradingEnabled = true;
        emit TradingOnUniSwapEnabled();
    }

    /// @notice This function is used to disable trading on Uniswap
    function DisableTradingOnUniSwap() external onlyOwner {
        isTradingEnabled = false;
        emit TradingOnUniSwapDisabled();
    }

    // ========== ERC20 Overrides ==========
    /// @notice overriden ERC20 transfer to tax on transfers to and from the uniswap pair, xperp is swapped to ETH and prepared for snapshot distribution
    function _update(address from, address to, uint256 amount) internal override {
        bool isTradingTransfer =
            (from == uniswapV2Pair || to == uniswapV2Pair) &&
            msg.sender != address(uniswapV2Router) &&
            from != address(this) && to != address(this);

        require(isTradingEnabled || !isTradingTransfer, "Trading is not enabled yet");

        // if trading is enabled, only allow transfers to and from the Uniswap pair
        uint256 amountAfterTax = amount;
        // calculate 5% swap tax
        // owner() is an exception to fund the liquidity pair and revenueDistributionBot as well to fund the revenue distribution to holders
        if (isTradingTransfer) {
            require(isTradingEnabled, "Trading is not enabled yet");
            // Buying tokens
            if (from == uniswapV2Pair && walletBalanceLimit > 0) {
                require(balanceOf(to) + amount <= walletBalanceLimit, "Holding amount after buying exceeds maximum allowed tokens.");
            }
            // Selling tokens
            if (to == uniswapV2Pair && sellLimit > 0) {
                require(amount <= sellLimit, "Selling amount exceeds maximum allowed tokens.");
            }
            // 5% total tax on xperp traded (1% to LP, 2% to revenue share, 2% to team and operating expenses).
            if (tax > 0) {
                uint256 taxAmountToken = (amount * tax) / hundredPercent;
                _transfer(from, address(this), taxAmountToken);
                emit Taxed(from, taxAmountToken);
                amountAfterTax -= taxAmountToken;
            }
        }
        super._update(from, to, amountAfterTax);
    }

    // ========== Revenue Sharing ==========

    /// @notice Function called by the revenue distribution bot to snapshot the state
    function snapshot() external payable nonReentrant {
        uint256 tokenToSwap = balanceOf(address(this));
        require(tokenToSwap > 0, "Zero balance");
        uint256 swappedETH = swapTokenToETH(tokenToSwap);
        teamWallet.transfer(swappedETH);
        emit Snapshot(tokenToSwap, swappedETH);
    }

    // ========== Internal Functions ==========
    function swapTokenToETH(uint256 _amount) internal returns (uint256) {
        if (_amount == 0) return 0;
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = uniswapV2Router.WETH();
        uint256 initialETHBalance = address(this).balance;
        uniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            _amount,
            0,
            path,
            address(this),
            block.timestamp
        );
        uint256 finalETHBalance = address(this).balance;
        uint256 ETHReceived = finalETHBalance - initialETHBalance;
        emit SwappedToEth(_amount, ETHReceived);
        return ETHReceived;
    }

    // ========== Rescue Functions ==========

    function rescueETH(uint256 _weiAmount) external {
        payable(teamWallet).transfer(_weiAmount);
    }

    function rescueERC20(address _tokenAdd, uint256 _amount) external {
        IERC20(_tokenAdd).transfer(teamWallet, _amount);
    }

    // ========== Fallbacks ==========


    receive() external payable {
        emit ReceivedEther(msg.sender, msg.value);
    }

}
