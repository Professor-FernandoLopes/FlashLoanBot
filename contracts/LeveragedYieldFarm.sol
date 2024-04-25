// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.18;

import "@balancer-labs/v2-interfaces/contracts/vault/IVault.sol";
import "@balancer-labs/v2-interfaces/contracts/vault/IFlashLoanRecipient.sol";

/// @dev Interface for Compound's cERC20 Token
interface ICToken {
    function mint(uint mintAmount) external returns (uint);

    function borrow(uint borrowAmount) external returns (uint);

    function repayBorrow(uint repayAmount) external returns (uint);

    function redeem(uint redeemTokens) external returns (uint);

    function borrowBalanceCurrent(address account) external returns (uint);

    function balanceOf(address owner) external view returns (uint);
}

/// @dev Interface for Compound's Comptroller
interface IComptroller {
    function enterMarkets(
        address[] calldata
    ) external returns (uint256[] memory);

    function claimComp(address holder) external;
}

contract LeveragedYieldFarm is IFlashLoanRecipient {
    // DAI Token
    // https://etherscan.io/address/0x6b175474e89094c44da98b954eedeac495271d0f
    address constant daiAddress = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    IERC20 constant dai = IERC20(daiAddress);

    // Compound's cDai Token
    // https://etherscan.io/address/0x5d3a536e4d6dbd6114cc1ead35777bab948e3643
    address constant cDaiAddress = 0x5d3a536E4D6DbD6114cc1Ead35777bAB948E3643;
    ICToken constant cDai = ICToken(cDaiAddress);

    // Compound's COMP ERC-20 token
    // https://etherscan.io/token/0xc00e94cb662c3520282e6f5717214004a7f26888
    IERC20 constant compToken =
        IERC20(0xc00e94Cb662C3520282E6f5717214004A7f26888);

    // Mainnet Comptroller
    // https://etherscan.io/address/0x3d9819210a31b4961b30ef54be2aed79b9c9cd3b
    IComptroller constant comptroller =
        IComptroller(0x3d9819210A31b4961b30EF54bE2aeD79B9c9Cd3B);

    // Balancer Contract
    // https://etherscan.io/address/0xBA12222222228d8Ba445958a75a0704d566BF2C8
    IVault constant vault = IVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);

    // Contract owner
    address immutable owner;

    struct MyFlashData {
        address flashToken;
        uint256 flashAmount;
        uint256 totalAmount;
        bool isDeposit;
    }

    modifier onlyOwner() {
        require(
            msg.sender == owner,
            "LeveragedYieldFarm: caller is not the owner!"
        );
        _;
    }

    constructor() {
        owner = msg.sender;

        // Enter the cDai market so you can borrow another type of asset
        address[] memory cTokens = new address[](1);
        cTokens[0] = cDaiAddress;
        uint256[] memory errors = comptroller.enterMarkets(cTokens);
        if (errors[0] != 0) {
            revert("Comptroller.enterMarkets failed.");
        }
    }

    /// @notice Don't allow contract to receive Ether by mistake
    fallback() external {
        revert();
    }

    /// @notice You must first send DAI to this contract before you can call this function
    /// @notice Always keep at least 1 DAI in the contract
    function depositDai(
        uint256 initialAmount
    ) external onlyOwner returns (bool) {
        // Total deposit: 30% initial amount, 70% flash loan
        uint256 totalAmount = (initialAmount * 10) / 3;

        // loan is 70% of total deposit
        uint256 flashLoanAmount = totalAmount - initialAmount;

        // Get DAI Flash Loan for "DEPOSIT"
        bool isDeposit = true;
        getFlashLoan(daiAddress, flashLoanAmount, totalAmount, isDeposit); // execution goes to `receiveFlashLoan`

        // Handle remaining execution inside handleDeposit() function

        return true;
    }

    /// @notice Always keep at least 1 DAI in the contract
    function withdrawDai(
        uint256 initialAmount
    ) external onlyOwner returns (bool) {
        // Total deposit: 30% initial amount, 70% flash loan
        uint256 totalAmount = (initialAmount * 10) / 3;

        // Loan is 70% of total deposit
        uint256 flashLoanAmount = totalAmount - initialAmount;

        // Use flash loan to payback borrowed amount
        bool isDeposit = false; //false means withdraw
        getFlashLoan(daiAddress, flashLoanAmount, totalAmount, isDeposit); // execution goes to `receiveFlashLoan`

        // Handle repayment inside handleWithdraw() function

        // Claim COMP tokens
        comptroller.claimComp(address(this));

        // Withdraw COMP tokens
        compToken.transfer(owner, compToken.balanceOf(address(this)));

        // Withdraw Dai to the wallet
        dai.transfer(owner, dai.balanceOf(address(this)));

        return true;
    }

    function getFlashLoan(
        address flashToken,
        uint256 flashAmount,
        uint256 totalAmount,
        bool isDeposit
    ) internal {
        // Encode MyFlashData for `receiveFlashLoan`
        bytes memory userData = abi.encode(
            MyFlashData({
                flashToken: flashToken,
                flashAmount: flashAmount,
                totalAmount: totalAmount,
                isDeposit: isDeposit
            })
        );

        // Token to flash loan, by default we are flash loaning 1 token.
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(flashToken);

        // Flash loan amount.
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = flashAmount;

        vault.flashLoan(this, tokens, amounts, userData); // execution goes to `receiveFlashLoan`
    }

    /**
     * @dev This is the function that will be called postLoan
     * i.e. Encode the logic to handle your flashloaned funds here
     */
    function receiveFlashLoan(
        IERC20[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external {
        require(
            msg.sender == address(vault),
            "LeveragedYieldFarm: Not Balancer!"
        );

        MyFlashData memory data = abi.decode(userData, (MyFlashData));
        uint256 flashTokenBalance = IERC20(data.flashToken).balanceOf(
            address(this)
        );

        require(
            flashTokenBalance >= data.flashAmount + feeAmounts[0],
            "LeveragedYieldFarm: Not enough funds to repay Balancer loan!"
        );

        if (data.isDeposit == true) {
            handleDeposit(data.totalAmount, data.flashAmount);
        }

        if (data.isDeposit == false) {
            handleWithdraw();
        }

        IERC20(data.flashToken).transfer(
            address(vault),
            (data.flashAmount + feeAmounts[0])
        );
    }

    function handleDeposit(
        uint256 totalAmount,
        uint256 flashLoanAmount
    ) internal returns (bool) {
        // Approve Dai tokens as collateral
        dai.approve(cDaiAddress, totalAmount);

        // Provide collateral by minting cDai tokens
        cDai.mint(totalAmount);

        // Borrow Dai
        cDai.borrow(flashLoanAmount);

        // Start earning COMP tokens, yay!
        return true;
    }

    function handleWithdraw() internal returns (bool) {
        uint256 balance;

        // Get curent borrow Balance
        balance = cDai.borrowBalanceCurrent(address(this));

        // Approve tokens for repayment
        dai.approve(address(cDai), balance);

        // Repay tokens
        cDai.repayBorrow(balance);

        // Get cDai balance
        balance = cDai.balanceOf(address(this));

        // Redeem cDai
        cDai.redeem(balance);

        return true;
    }

    /// @dev Fallback in case any other tokens are sent to this contract
    function withdrawToken(address _tokenAddress) public onlyOwner {
        uint256 balance = IERC20(_tokenAddress).balanceOf(address(this));
        IERC20(_tokenAddress).transfer(owner, balance);
    }
}
