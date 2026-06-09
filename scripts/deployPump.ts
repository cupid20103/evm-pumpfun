import { ethers } from "hardhat";

async function main() {
	console.log("Starting deployment...");

	// Uniswap V2 (compatible) router on the target network.
	const routerAddress = process.env.ROUTER_ADDRESS;
	if (!routerAddress) {
		throw new Error("Set ROUTER_ADDRESS in your environment before deploying");
	}

	const PumpFactoryFactory = await ethers.getContractFactory("PumpCloneFactory");
	const pumpFactory = await PumpFactoryFactory.deploy(routerAddress);
	await pumpFactory.waitForDeployment();

	console.log("PumpCloneFactory deployed at:", await pumpFactory.getAddress());
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main()
	.then(() => process.exit(0))
	.catch((error) => {
		console.error(error);
		process.exit(1);
	});
