// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Spectra IMD (SPECTRA)
/// @notice A fixed supply ERC-20 with 18 decimals and no administrative powers.
contract SpectraToken is ERC20 {
    /// @notice Ten million SPECTRA, expressed in the token's smallest units.
    uint256 public constant INITIAL_SUPPLY = 10_000_000 * 10 ** 18;

    /// @notice Mints the entire supply once to the immediate deployer.
    /// @dev When deployed by the launch factory, the factory receives the supply.
    constructor() ERC20("Spectra IMD", "SPECTRA") {
        _mint(msg.sender, INITIAL_SUPPLY);
    }
}
