# Spectra IMD (SPECTRA)

A fixed supply ERC-20 token. The only production contract is
[`src/SpectraToken.sol`](src/SpectraToken.sol), named `SpectraToken` in Solidity.

| Property | Value |
| --- | --- |
| Name | Spectra IMD |
| Symbol | SPECTRA |
| Decimals | 18 |
| Supply in whole tokens | 10,000,000 |
| Supply in smallest units | `10000000000000000000000000` |
| Constructor arguments | None (`[]`) |
| Constructor value | 0 ETH |
| Initial recipient | Immediate deployer (`msg.sender`) |

The constructor mints the entire supply once. The contract uses the vendored
OpenZeppelin Contracts v5.1.0 ERC-20 implementation. No function can subsequently
mint or burn tokens. There is no owner, upgrade mechanism, pause, blacklist,
transfer tax, rebase, vesting, or privileged seizure function. All holders follow
the same transfer and allowance rules, including the deploying factory.

## Build and test

Run from this repository's root with Foundry installed:

```sh
forge build
forge test
forge fmt --check
```

`foundry.toml` pins Solidity **0.8.26**, the Cancun EVM target, optimization at
200 runs, and `bytecode_hash = "none"`. FFI and filesystem cheatcode permissions
are disabled. The verifier must have Solidity 0.8.26 installed; no compiler binary
is shipped. All Solidity dependencies and their licenses are ordinary files in
`lib/`, so there is no dependency installation or network requirement at build
time. Exact upstream commits are recorded in
[`lib/dependencies.json`](lib/dependencies.json).

For a clean offline check once that compiler is available:

```sh
forge build --offline --force
forge test --offline
```

Tests use isolated fixtures with no RPC, environment variables, wallet keys, or
filesystem access. They cover:

- Metadata, initial balances, the mint event, and direct and CREATE2 deployment.
- Exact transfers, self transfers, zero transfers, and transfers to contracts
  that reject callbacks.
- Approvals, replacement and revocation, finite and infinite allowances, and
  delegated transfers.
- Insufficient balance or allowance, unauthorized spending, invalid recipients,
  and rollback of allowances when a transfer fails.
- Exact distribution and claim amounts, token movement into and out of pool
  custody, rejection of mint/admin selectors, and prohibited runtime opcodes.
- Four parameterized fuzz tests at 256 runs each and a stateful invariant
  campaign at 128 runs of 64 calls, checking every balance and allowance against
  an independent accounting model and preserving the fixed supply.

The launch transfer fixture checks token accounting. It does not implement a
Uniswap pool or demonstrate real pool initialization, liquidity provision, or
swaps. The supplied protected integration test requires the network's factory
infrastructure, v4 dependencies, and manifest-derived parameters, which are not
present in this standalone repository. That integration remains the network
verifier's responsibility. The token's constructor does not call external
contracts and requires no pre-existing deployment.

## Deployment parameters and assumptions

Deploy **`src/SpectraToken.sol:SpectraToken`** using the creation bytecode from
`out/SpectraToken.sol/SpectraToken.json`. Append no constructor arguments, attach
no ETH, and make no initialization call. There are no linked external libraries
or application contracts to deploy.

The intended launch is Ethereum, chain ID 1. The token does not hardcode a chain,
factory address, pool manager, distributor, or recipient. The immediate creator
receives all `10000000000000000000000000` units. During the requested factory
launch this is the factory, which then performs distribution. A direct wallet
deployment would instead allocate everything to that wallet. Do not deploy
through an unrelated helper that cannot forward the tokens.

The launch system separately supplies the following policy and economics from
the assignment; none is a constructor parameter or a transfer rule in this token:

| Launch setting | Assignment value |
| --- | --- |
| Paired currency | IMD at `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` (18 decimals) |
| Pool fee | `12500` (1.25%) |
| Tick spacing | `60` |
| Initial price provenance | `79228162514264337593543950336` |
| Initial market capitalization | `2500000000000000000000` IMD minor units (2,500 IMD) |
| Pool allocation | `8000` basis points: 8,000,000 SPECTRA |
| Swarm allocation | 1,000,000 SPECTRA, transferred by the factory to its distributor |
| Remainder | 1,000,000 SPECTRA to `0x6bf192ebef135e0f645e99d59d9bf44e7711606c` |

The launch system derives the actual pool opening price from capitalization,
supply, and token ordering. The manifest step owns `launch.json` and must use
`SpectraToken`, the exact metadata and smallest-unit supply above, and empty
constructor arguments. This project does not write that manifest, distribute
tokens in its constructor, broadcast transactions, or manage a wallet.

## After launch

No token settings, owner assignments, keepers, or initialization transactions are
required. The network's launch operator is responsible for deploying through the
intended factory, executing distribution and pool setup, and verifying the
deployed source and compiler settings on an explorer. Confirm the metadata,
fixed total supply, mint event recipient, and final distribution against the
accepted manifest and transaction receipt.

Holders control their balances through `transfer` and authorize spenders through
`approve`. Successful state-changing ERC-20 calls return `true`; invalid calls
revert with OpenZeppelin's ERC-6093 errors. Zero-value transfers to valid
addresses succeed and emit `Transfer`. Transfers to the zero address and
approvals to a zero spender revert.

Approvals replace the existing allowance. A spender can use an outstanding
allowance until it is spent or revoked; use appropriately limited approvals and
revoke stale ones. When replacing a nonzero allowance, confirm its revocation
before granting the replacement to reduce the standard ERC-20 approval race.
An allowance of `type(uint256).max` is unlimited and does not decrease on
`transferFrom`. Explicit approvals emit `Approval`; allowance consumption does
not emit another `Approval` in this OpenZeppelin version, so integrations should
query `allowance` for its current value.

There is no recovery function for tokens sent to this contract or other addresses
unable to transfer them. Ordinary ETH transfers revert. Lost keys, erroneous
transfers, and outstanding approvals cannot be repaired by an administrator.
The deployer has control over the initial supply only through its balance and
has no continuing authority over other holders.

## Security review scope

The local review checked the constructor's sole mint, the reachable ERC-20
methods, authorization through balances and allowances, transfer failure
atomicity, and the absence of external calls or administrative entry points.
Supply arithmetic uses the requested 18-decimal unit scale. Internal mint/burn
helpers inherited from OpenZeppelin are not external entry points, and the token
exposes neither. No oracle, randomness, signature, or upgrade machinery is used.

Foundry unit, fuzz, invariant, and bytecode checks were run locally. Slither and
Mythril were not run. This work is not an independent security audit; the
network's separate review and protected launch integration checks remain release
responsibilities.
