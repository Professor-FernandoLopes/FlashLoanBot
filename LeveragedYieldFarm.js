const hre = require("hardhat")
const { mine } = require("@nomicfoundation/hardhat-network-helpers")
const { expect } = require("chai")

const ERC20 = require('@openzeppelin/contracts/build/contracts/ERC20.json')
const UniswapV2Router02 = require('@uniswap/v2-periphery/build/IUniswapV2Router02.json')

describe('LeveragedYieldFarm', () => {
  const UNISWAP_ROUTER = "0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D"
  const WETH = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
  const DAI = "0x6B175474E89094C44Da98b954EedeAC495271d0F"
  const cDAI = "0x5d3a536E4D6DbD6114cc1Ead35777bAB948E3643"
  const COMP = "0xc00e94Cb662C3520282E6f5717214004A7f26888"

  let deployer // <-- Accounts
  let uRouter, dai, cDai, comp, leveragedYieldFarm // <-- Contracts

  beforeEach(async () => {
    [deployer] = await hre.ethers.getSigners()

    // Setup Uniswap V2 Router contract...
    // This will be used to swap 1 ETH for some DAI, that way, we can transfer DAI to the contract
    uRouter = new hre.ethers.Contract(UNISWAP_ROUTER, UniswapV2Router02.abi, deployer)

    // Setup DAI contract...
    dai = new hre.ethers.Contract(DAI, ERC20.abi, deployer)

    // Setup Compound contracts cDAI & COMP...
    cDai = new hre.ethers.Contract(cDAI, ERC20.abi, deployer)
    comp = new hre.ethers.Contract(COMP, ERC20.abi, deployer)

    // Deploy LeveragedYieldFarm...
    leveragedYieldFarm = await hre.ethers.deployContract("LeveragedYieldFarm")
  })

  describe('Swapping 1 ETH for DAI...', () => {
    const PATH = [WETH, DAI]
    const AMOUNT = hre.ethers.parseUnits('1', 'ether')
    const DEADLINE = Math.floor(Date.now() / 1000) + 60 * 20

    it('Swaps ETH for DAI', async () => {
      const ethBalanceBefore = await hre.ethers.provider.getBalance(deployer.address)
      const daiBalanceBefore = await dai.connect(deployer).balanceOf(deployer.address)

      await uRouter.connect(deployer).swapExactETHForTokens(0, PATH, deployer.address, DEADLINE, { value: AMOUNT })

      const ethBalanceAfter = await hre.ethers.provider.getBalance(deployer.address)
      const daiBalanceAfter = await dai.balanceOf(deployer.address)

      expect(daiBalanceAfter).to.be.above(daiBalanceBefore)
      expect(ethBalanceAfter).to.be.below(ethBalanceBefore)
    })
  })

  describe('Sending ETH', () => {
    it('Reverts if ETH is sent by accident', async () => {
      await expect(deployer.sendTransaction({
        to: await leveragedYieldFarm.getAddress(),
        value: hre.ethers.parseUnits('1', 'ether')
      })).to.be.reverted
    })
  })

  describe('Leveraged Yield Farming on Compound boosted with Balancer flash loan...', () => {
    beforeEach(async () => {
      // Deposit 1.1 DAI to contract (.1 for additional headroom when withdrawing)
      await dai.connect(deployer).transfer(
        await leveragedYieldFarm.getAddress(),
        hre.ethers.parseUnits('1.1', 'ether')
      )

      // Supplying 1 DAI with flash loan to Compound
      await leveragedYieldFarm.connect(deployer).depositDai(hre.ethers.parseUnits('1', 'ether'))
    })

    it('Deposits/Waits/Withdraws/Takes Profit...', async () => {
      const ethBalanceBefore = await hre.ethers.provider.getBalance(deployer.address)
      const daiBalanceBefore = await dai.balanceOf(deployer.address)
      const cDaiBalanceBefore = await cDai.balanceOf(await leveragedYieldFarm.getAddress())
      const compBalanceBefore = await comp.balanceOf(deployer.address)

      // Fast forward 1 block...
      // New blocks are validated roughly every ~ 12 seconds
      const BLOCKS_TO_MINE = 1

      console.log(`\nFast forwarding ${BLOCKS_TO_MINE} Block...\n`)

      await mine(BLOCKS_TO_MINE, { interval: 12 })

      // Taking profits
      await leveragedYieldFarm.connect(deployer).withdrawDai(hre.ethers.parseUnits('1', 'ether'))

      const ethBalanceAfter = await hre.ethers.provider.getBalance(deployer.address)
      const daiBalanceAfter = await dai.balanceOf(deployer.address)
      const cDaiBalanceAfter = await cDai.balanceOf(await leveragedYieldFarm.getAddress())
      const compBalanceAfter = await comp.balanceOf(deployer.address)

      expect(ethBalanceBefore).to.be.above(ethBalanceAfter) // Due to gas fee
      expect(daiBalanceAfter).to.be.above(daiBalanceBefore) // Interest for supplying
      expect(cDaiBalanceBefore).to.be.above(cDaiBalanceAfter) // Swapping cDAI => DAI
      expect(compBalanceAfter).to.be.above(compBalanceBefore) // Successful yield farm

      const results = {
        "ethBalanceBefore": hre.ethers.formatUnits(ethBalanceBefore.toString(), 'ether'),
        "ethBalanceAfter": hre.ethers.formatUnits(ethBalanceAfter.toString(), 'ether'),
        "daiBalanceBefore": hre.ethers.formatUnits(daiBalanceBefore, 'ether'),
        "daiBalanceAfter": hre.ethers.formatUnits(daiBalanceAfter, 'ether'),
        "cDaiBalanceBefore": hre.ethers.formatUnits(cDaiBalanceBefore, 'ether'),
        "cDaiBalanceAfter": hre.ethers.formatUnits(cDaiBalanceAfter, 'ether'),
        "compBalanceAfter": hre.ethers.formatUnits(compBalanceAfter, 'ether')
      }

      console.table(results)
    })
  })
})