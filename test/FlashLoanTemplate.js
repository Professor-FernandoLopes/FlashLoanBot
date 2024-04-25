const hre = require("hardhat")
const { expect } = require("chai")

const ERC20 = require('@openzeppelin/contracts/build/contracts/ERC20.json')

describe("FlashLoanTemplate", function () {
  const DAI = "0x6B175474E89094C44Da98b954EedeAC495271d0F"
  const AMOUNT = hre.ethers.parseUnits('1000000', 'ether')

  let deployer // <-- Accounts
  let dai, flashLoanTemplate // <-- Contracts

  beforeEach(async () => {
    [deployer] = await hre.ethers.getSigners()

    flashLoanTemplate = await hre.ethers.deployContract("FlashLoanTemplate")

    dai = new ethers.Contract(DAI, ERC20.abi, hre.ethers.provider)
  })

  describe("Performing Flash Loan...", () => {
    it('Borrows 1M DAI and Emits Event', async () => {
      expect(await flashLoanTemplate.connect(deployer).getFlashloan(DAI, AMOUNT))
        .to.emit(flashLoanTemplate, "FlashLoan").withArgs(DAI, AMOUNT)
    })
  })
})
