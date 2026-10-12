// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SpectraToken} from "../src/SpectraToken.sol";

/// @dev Test-only deployment helper; never a production deployment artifact.
contract TokenFactoryFixture {
    function deploy(bytes32 salt) external returns (SpectraToken) {
        return new SpectraToken{salt: salt}();
    }
}

contract SpectraTokenLaunchTest is Test {
    uint256 private constant SUPPLY = 10_000_000 * 10 ** 18;
    TokenFactoryFixture private factory;
    SpectraToken private token;

    function setUp() public {
        factory = new TokenFactoryFixture();
        token = factory.deploy(keccak256("Spectra launch fixture"));
    }

    function test_Create2DeploymentMintsEverythingToFactory() public view {
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                address(factory),
                keccak256("Spectra launch fixture"),
                keccak256(type(SpectraToken).creationCode)
            )
        );
        // CREATE2 addresses are the low 160 bits of the specified hash.
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(address(token), address(uint160(uint256(hash))));
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(factory)), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(token)), 0);
    }

    /// @dev Checks exact token movement only; the launch verifier supplies the real v4 pool.
    function test_DistributionClaimsAndPoolTransfersDeliverFullAmounts() public {
        address distributor = makeAddr("distributor fixture");
        address pool = makeAddr("pool custody fixture");
        address remainderRecipient = makeAddr("remainder fixture");
        address claimant = makeAddr("claimant fixture");
        address trader = makeAddr("trader fixture");

        uint256 swarmAmount = SUPPLY / 10;
        uint256 poolAmount = SUPPLY * 8 / 10;
        uint256 remainderAmount = SUPPLY - swarmAmount - poolAmount;
        vm.startPrank(address(factory));
        assertTrue(token.transfer(distributor, swarmAmount));
        assertTrue(token.transfer(pool, poolAmount));
        assertTrue(token.transfer(remainderRecipient, remainderAmount));
        vm.stopPrank();

        assertEq(token.balanceOf(address(factory)), 0);
        assertEq(token.balanceOf(distributor), swarmAmount);
        assertEq(token.balanceOf(pool), poolAmount);
        assertEq(token.balanceOf(remainderRecipient), remainderAmount);

        vm.prank(distributor);
        assertTrue(token.transfer(claimant, swarmAmount));
        assertEq(token.balanceOf(distributor), 0);
        assertEq(token.balanceOf(claimant), swarmAmount);

        vm.prank(pool);
        assertTrue(token.transfer(trader, 321 ether));
        assertEq(token.balanceOf(trader), 321 ether);
        assertEq(token.balanceOf(pool), poolAmount - 321 ether);
        vm.prank(trader);
        assertTrue(token.transfer(pool, 321 ether));
        assertEq(token.balanceOf(trader), 0);
        assertEq(token.balanceOf(pool), poolAmount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_MintAndAdministrativeSelectorsRevertForFactoryAndStranger() public {
        address holder = makeAddr("holder");
        address stranger = makeAddr("stranger");
        vm.prank(address(factory));
        token.transfer(holder, 10 ether);

        bytes[] memory calls = new bytes[](24);
        calls[0] = abi.encodeWithSignature("mint(address,uint256)", stranger, 1 ether);
        calls[1] = abi.encodeWithSignature("mint(uint256)", 1 ether);
        calls[2] = abi.encodeWithSignature("mint()");
        calls[3] = abi.encodeWithSignature("issue(uint256)", 1 ether);
        calls[4] = abi.encodeWithSignature("setOwner(address)", stranger);
        calls[5] = abi.encodeWithSignature("transferOwnership(address)", stranger);
        calls[6] = abi.encodeWithSignature("upgradeTo(address)", stranger);
        calls[7] = abi.encodeWithSignature("initialize(address)", stranger);
        calls[8] = abi.encodeWithSignature("unpause()");
        calls[9] = abi.encodeWithSignature("setMinter(address)", stranger);
        calls[10] = abi.encodeWithSignature("pause()");
        calls[11] = abi.encodeWithSignature("blacklist(address)", holder);
        calls[12] = abi.encodeWithSignature("blocklist(address)", holder);
        calls[13] = abi.encodeWithSignature("freeze(address)", holder);
        calls[14] = abi.encodeWithSignature("freezeAccount(address)", holder);
        calls[15] = abi.encodeWithSignature("setBlacklist(address,bool)", holder, true);
        calls[16] = abi.encodeWithSignature("setBlocked(address,bool)", holder, true);
        calls[17] = abi.encodeWithSignature("lock(address)", holder);
        calls[18] = abi.encodeWithSignature("disableTransfers()");
        calls[19] = abi.encodeWithSignature("setTransfersEnabled(bool)", false);
        calls[20] = abi.encodeWithSignature("burnFrom(address,uint256)", holder, 1 ether);
        calls[21] = abi.encodeWithSignature("seize(address)", holder);
        calls[22] = abi.encodeWithSignature("burn(uint256)", 1 ether);
        calls[23] = abi.encodeWithSignature("initialize()");

        for (uint256 i; i < calls.length; ++i) {
            vm.prank(address(factory));
            (bool factorySucceeded,) = address(token).call(calls[i]);
            assertFalse(factorySucceeded, "factory reached unexpected function");
            vm.prank(stranger);
            (bool strangerSucceeded,) = address(token).call(calls[i]);
            assertFalse(strangerSucceeded, "stranger reached unexpected function");
            assertEq(token.totalSupply(), SUPPLY);
            assertEq(token.balanceOf(holder), 10 ether);
            assertEq(token.balanceOf(stranger), 0);
        }

        vm.prank(holder);
        assertTrue(token.transfer(stranger, 10 ether));
        assertEq(token.balanceOf(holder), 0);
        assertEq(token.balanceOf(stranger), 10 ether);
    }

    function test_RuntimeHasNoProhibitedOpcodes() public view {
        bytes memory code = address(token).code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 opcode = uint8(code[i]);
            if (opcode >= 0x60 && opcode <= 0x7f) {
                i += opcode - 0x5f;
                continue;
            }
            assertTrue(opcode != 0xf4, "DELEGATECALL");
            assertTrue(opcode != 0xf2, "CALLCODE");
            assertTrue(opcode != 0xff, "SELFDESTRUCT");
        }
    }
}
