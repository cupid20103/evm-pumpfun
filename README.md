# PumpFun EVM Smart Contract

A Pump.fun-style token launchpad for EVM chains. Anyone can deploy a fresh ERC-20
in a single transaction, trade it against an embedded constant-product bonding
curve, and have its liquidity migrate automatically to Uniswap V2 once the curve
graduates. Built for Monad's EVM-compatible testnet and interoperable with
standard Ethereum tooling.

---

## Key Features

- **One-click token creation**: `launchToken(name, symbol)` deploys a new
  `PumpToken` (OpenZeppelin ERC-20) with a fixed final supply of 1,000,000,000
  tokens and seeds its bonding curve. An optional ETH value performs an initial
  dev buy in the same transaction.
- **Bonding curve pricing**: a constant-product virtual-reserve curve
  (Pump.fun-style) provides fair price discovery and rewards early buyers.
- **Onchain buy and sell**: trade against the curve at any time via `buyToken`
  and `sellToken`. Supply is minted on buys and burned on sells; each trade takes
  a configurable fee (default 1%) claimable by the protocol owner.
- **Automatic Uniswap migration**: once the curve's token reserve is fully sold
  (graduation), the pooled ETH and the reserved token allocation are added to a
  Uniswap V2 pool and the LP tokens are burned to permanently lock liquidity.
- **Fully onchain**: minting, pricing, fee accounting, and migration all execute
  onchain.

---

## How It Works

1. **Launch**: `launchToken(name, symbol)` deploys a `PumpToken` and initializes
   its reserves (`V_ETH_RESERVE`, `V_TOKEN_RESERVE`, `R_TOKEN_RESERVE`). Sending
   ETH triggers an immediate initial buy.
2. **Trade**: `buyToken(token, minTokensOut)` mints tokens along the curve, and
   `sellToken(token, amount, minEthOut)` burns them back for ETH. Both apply the
   trade fee and honour their slippage guard.
3. **Graduate**: when the real token reserve is exhausted, the buy that completes
   it is capped at the remaining supply (excess ETH refunded) and
   `_migrateLiquidity` mints the LP allocation (`TOTAL_SUPPLY - totalSupply`),
   pairs it with the accumulated ETH minus `LIQUIDITY_MIGRATION_FEE`, and calls
   `addLiquidityETH` on the router. After migration, curve trading is disabled and
   the token trades on Uniswap.

### Default parameters

| Parameter                 | Value                  |
| ------------------------- | ---------------------- |
| `TOTAL_SUPPLY`            | 1,000,000,000 tokens   |
| `R_TOKEN_RESERVE`         | 793,100,000 tokens     |
| `V_TOKEN_RESERVE`         | 1,073,000,000 tokens   |
| `V_ETH_RESERVE`           | 0.015 ETH              |
| `TRADE_FEE_BPS`           | 100 (1%, max 10%)      |
| `LIQUIDITY_MIGRATION_FEE` | 0.018 ETH              |

Reserves, trade fee, and migration fee are adjustable by the owner via
`updateReserves`, `updateFeeRate`, and `updateLiquidityMigrationFee`. Accrued
trade and migration fees are withdrawn with `claimFee`.

---

## Contracts

- `contracts/PumpFactory.sol`
  - `PumpToken`: minimal ERC-20 whose supply is controlled by the factory.
  - `PumpCloneFactory`: launch, trade, fee, and migration logic.
- `contracts/mocks/`: `MockWETH` and `MockUniswapV2Router` used only by the test
  suite to exercise the migration path locally.

---

## Technical Stack

- **Language:** Solidity 0.8.28
- **Blockchain:** Monad testnet (chain ID 10143)
- **Token standard:** OpenZeppelin ERC-20
- **DEX integration:** Uniswap V2 (`addLiquidityETH`)
- **Tooling:** Hardhat, Ethers v6, TypeChain

---

## Build and Test

```bash
npm install
npx hardhat compile
npx hardhat test
```

The test suite covers launch, buy/sell, fee accounting, slippage guards, the ETH
accounting invariant, and the full graduation-to-Uniswap migration path against a
mock router.

### Deploy

Set `PRIVATE_KEY` and `ROUTER_ADDRESS` in a `.env` file, then:

```bash
npm run deploy
```

---

## Proof of Work

[Contract Address](https://testnet.monadexplorer.com/address/0x802Bbb3924BEE46831cadD23e9CfA9e74B499Efb)

- [Launch Token](https://testnet.monadexplorer.com/tx/0x44ce82f48eabc5e5f1be7bfb6414d380071a4993cd458b191d571568bb2c3190)
- [Buy Tx](https://testnet.monadexplorer.com/tx/0xaf91c0e9254248b27310652da1c1bdfbf7a40d88cf7c72b0fabbd76ce24ec160)
- [Sell Tx](https://testnet.monadexplorer.com/tx/0x3058ceca20593a1acff0e4c3534a92243ff554dc951f40e61a87476b75c29e9d)
- [Buy and Migration to Uniswap](https://testnet.monadexplorer.com/tx/0x1dd9da4ec6acab116cc2b4a24c97ff5e6a93a0fe5ce0c8413436a0489243cad2)

---

## Notes

- Currently targeting Monad testnet; awaiting Monad mainnet for production launch.
- Bonding curve mechanics mirror Solana Pump.fun's pricing structure.
- Liquidity migration requires the curve's full token reserve to be sold, after
  which the accumulated ETH (minus the migration fee) seeds the Uniswap pool.

---

## Credits

Inspired by the original [Pump.fun](https://pump.fun) on Solana, re-engineered for
EVM chains starting with Monad.

---

## Contributing

PRs, issues, and feature suggestions are welcome. Feel free to fork, build, and
contribute.

---

## Contact

For inquiries, custom integrations, or tailored solutions, reach out via e-mail:
[kiyoshiaraki.dev@gmail.com](mailto:kiyoshiaraki.dev@gmail.com)
