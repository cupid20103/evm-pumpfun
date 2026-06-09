import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";

const ONE_ETH = ethers.parseEther("1");

describe("PumpCloneFactory", () => {
	async function deployFixture() {
		const [owner, alice, bob, feeReceiver] = await ethers.getSigners();

		const MockWETH = await ethers.getContractFactory("MockWETH");
		const weth = await MockWETH.deploy();

		const MockRouter = await ethers.getContractFactory("MockUniswapV2Router");
		const router = await MockRouter.deploy(await weth.getAddress());

		const Factory = await ethers.getContractFactory("PumpCloneFactory");
		const factory = await Factory.deploy(await router.getAddress());

		return { factory, router, weth, owner, alice, bob, feeReceiver };
	}

	// Launch a token and return its address (read from the TokenLaunched event).
	async function launch(factory: any, signer: any, value: bigint = 0n) {
		const tx = await factory
			.connect(signer)
			.launchToken("Pump Token", "PUMP", { value });
		const rc = await tx.wait();
		for (const log of rc!.logs) {
			try {
				const parsed = factory.interface.parseLog(log);
				if (parsed?.name === "TokenLaunched") return parsed.args.token as string;
			} catch {
				/* not a factory event */
			}
		}
		throw new Error("TokenLaunched event not found");
	}

	describe("Launch", () => {
		it("launches a token with no initial buy", async () => {
			const { factory, alice } = await loadFixture(deployFixture);
			const tokenAddr = await launch(factory, alice);

			const token = await ethers.getContractAt("PumpToken", tokenAddr);
			expect(await token.totalSupply()).to.equal(0n);
			expect(await token.factory()).to.equal(await factory.getAddress());

			const info = await factory.tokens(tokenAddr);
			expect(info.creator).to.equal(alice.address);
			expect(info.liquidityMigrated).to.equal(false);
			expect(info.rReserveToken).to.equal(await factory.R_TOKEN_RESERVE());
		});

		it("rejects empty name or symbol", async () => {
			const { factory, alice } = await loadFixture(deployFixture);
			await expect(
				factory.connect(alice).launchToken("", "PUMP")
			).to.be.revertedWith("Empty name");
			await expect(
				factory.connect(alice).launchToken("Pump", "")
			).to.be.revertedWith("Empty symbol");
		});

		it("performs an optional initial dev buy", async () => {
			const { factory, alice } = await loadFixture(deployFixture);
			const tokenAddr = await launch(factory, alice, ethers.parseEther("0.001"));

			const token = await ethers.getContractAt("PumpToken", tokenAddr);
			expect(await token.balanceOf(alice.address)).to.be.gt(0n);
			expect(await token.totalSupply()).to.equal(
				await token.balanceOf(alice.address)
			);
		});
	});

	describe("Buy / Sell", () => {
		it("buys tokens from the curve and accrues a 1% fee", async () => {
			const { factory, alice } = await loadFixture(deployFixture);
			const tokenAddr = await launch(factory, alice);
			const token = await ethers.getContractAt("PumpToken", tokenAddr);

			const spend = ethers.parseEther("0.001");
			await expect(
				factory.connect(alice).buyToken(tokenAddr, 0, { value: spend })
			).to.emit(factory, "TokensPurchased");

			expect(await token.balanceOf(alice.address)).to.be.gt(0n);
			expect(await factory.totalFee()).to.equal(spend / 100n); // 1%
		});

		it("enforces the buy slippage guard", async () => {
			const { factory, alice } = await loadFixture(deployFixture);
			const tokenAddr = await launch(factory, alice);
			await expect(
				factory.connect(alice).buyToken(tokenAddr, ethers.MaxUint256, {
					value: ethers.parseEther("0.001"),
				})
			).to.be.revertedWith("Slippage");
		});

		it("sells tokens back to the curve for ETH", async () => {
			const { factory, alice } = await loadFixture(deployFixture);
			const tokenAddr = await launch(factory, alice);
			const token = await ethers.getContractAt("PumpToken", tokenAddr);

			await factory
				.connect(alice)
				.buyToken(tokenAddr, 0, { value: ethers.parseEther("0.001") });

			const balance = await token.balanceOf(alice.address);
			const sellAmount = balance / 2n; // partial sell avoids 1-wei rounding edge

			const before = await ethers.provider.getBalance(alice.address);
			const tx = await factory
				.connect(alice)
				.sellToken(tokenAddr, sellAmount, 0);
			const rc = await tx.wait();
			const gas = rc!.gasUsed * rc!.gasPrice;
			const after = await ethers.provider.getBalance(alice.address);

			expect(after + gas).to.be.gt(before); // received net ETH
			expect(await token.balanceOf(alice.address)).to.equal(balance - sellAmount);
		});

		it("enforces the sell slippage guard", async () => {
			const { factory, alice } = await loadFixture(deployFixture);
			const tokenAddr = await launch(factory, alice);
			const token = await ethers.getContractAt("PumpToken", tokenAddr);
			await factory
				.connect(alice)
				.buyToken(tokenAddr, 0, { value: ethers.parseEther("0.001") });
			const balance = await token.balanceOf(alice.address);
			await expect(
				factory.connect(alice).sellToken(tokenAddr, balance / 2n, ethers.MaxUint256)
			).to.be.revertedWith("Slippage");
		});

		it("keeps the ETH accounting invariant (balance == rReserveEth + totalFee)", async () => {
			const { factory, alice, bob } = await loadFixture(deployFixture);
			const tokenAddr = await launch(factory, alice);
			const token = await ethers.getContractAt("PumpToken", tokenAddr);

			await factory
				.connect(alice)
				.buyToken(tokenAddr, 0, { value: ethers.parseEther("0.002") });
			await factory
				.connect(bob)
				.buyToken(tokenAddr, 0, { value: ethers.parseEther("0.003") });
			await factory
				.connect(alice)
				.sellToken(tokenAddr, (await token.balanceOf(alice.address)) / 2n, 0);

			const info = await factory.tokens(tokenAddr);
			const contractBalance = await ethers.provider.getBalance(
				await factory.getAddress()
			);
			expect(contractBalance).to.equal(info.rReserveEth + (await factory.totalFee()));
		});
	});

	describe("Graduation / Uniswap migration", () => {
		it("caps the buy at graduation, refunds excess, and migrates liquidity", async () => {
			const { factory, router, alice } = await loadFixture(deployFixture);
			const tokenAddr = await launch(factory, alice);
			const token = await ethers.getContractAt("PumpToken", tokenAddr);

			// Far more ETH than the curve needs -> forces graduation + refund.
			await expect(
				factory.connect(alice).buyToken(tokenAddr, 0, { value: ONE_ETH })
			).to.emit(factory, "LiquiditySwapped");

			const info = await factory.tokens(tokenAddr);
			expect(info.liquidityMigrated).to.equal(true);
			expect(info.rReserveEth).to.equal(0n);

			// Router received the LP token allocation and the paired ETH.
			expect(await router.lastAmountToken()).to.be.gt(0n);
			expect(await router.lastAmountETH()).to.be.gt(0n);
			expect(await router.lastTo()).to.equal(await factory.DEAD_ADDRESS());

			// Final supply equals the fixed TOTAL_SUPPLY.
			expect(await token.totalSupply()).to.equal(await factory.TOTAL_SUPPLY());
		});

		it("blocks trading once liquidity has migrated", async () => {
			const { factory, alice } = await loadFixture(deployFixture);
			const tokenAddr = await launch(factory, alice);
			await factory.connect(alice).buyToken(tokenAddr, 0, { value: ONE_ETH });

			await expect(
				factory.connect(alice).buyToken(tokenAddr, 0, { value: ONE_ETH })
			).to.be.revertedWith("Trading moved to Uniswap");
			await expect(
				factory.connect(alice).sellToken(tokenAddr, 1n, 0)
			).to.be.revertedWith("Trading moved to Uniswap");
		});
	});

	describe("Admin", () => {
		it("claims accrued fees to a chosen address", async () => {
			const { factory, alice, feeReceiver } = await loadFixture(deployFixture);
			const tokenAddr = await launch(factory, alice);
			await factory
				.connect(alice)
				.buyToken(tokenAddr, 0, { value: ethers.parseEther("0.001") });

			const fee = await factory.totalFee();
			expect(fee).to.be.gt(0n);

			await expect(
				factory.claimFee(feeReceiver.address)
			).to.changeEtherBalance(feeReceiver, fee);
			expect(await factory.totalFee()).to.equal(0n);
		});

		it("bounds the configurable fee rate", async () => {
			const { factory } = await loadFixture(deployFixture);
			await expect(factory.updateFeeRate(1001)).to.be.revertedWith("Fee too high");
			await factory.updateFeeRate(500);
			expect(await factory.TRADE_FEE_BPS()).to.equal(500n);
		});

		it("restricts admin functions to the owner", async () => {
			const { factory, alice } = await loadFixture(deployFixture);
			await expect(factory.connect(alice).updateFeeRate(50)).to.be.reverted;
			await expect(
				factory.connect(alice).claimFee(alice.address)
			).to.be.reverted;
		});
	});
});
