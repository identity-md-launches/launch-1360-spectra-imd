# Vendored dependencies

These are ordinary source files, with no submodules or installation step.
They are unmodified upstream files, except that only the required package
portions are included. `dependencies.json` records their exact source commits.

| Package | Version | Included files | License |
| --- | --- | --- | --- |
| [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/69c8def5f222ff96f2b5beff05dfba996368aa79) | v5.1.0 | ERC20, IERC20, IERC20Metadata, Context, IERC6093 interfaces | `openzeppelin-contracts/LICENSE` (MIT) |
| [Forge Standard Library](https://github.com/foundry-rs/forge-std/tree/77041d2ce690e692d6e03cc812b57d1ddaa4d505) | v1.9.7 | `src/` | `forge-std/LICENSE-APACHE` and `forge-std/LICENSE-MIT` |

Only OpenZeppelin is imported by production code. Forge Standard Library is
used by tests. Root remappings resolve both packages entirely inside this
repository. Upstream examples, package managers, test suites, and CI files are
not needed to build this project and are not included.
