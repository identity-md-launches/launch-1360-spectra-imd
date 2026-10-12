// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SpectraToken} from "../src/SpectraToken.sol";

/// @dev Deploys the token with raw CREATE so the test can attach ETH to a non-payable constructor,
/// which the Solidity type system otherwise refuses to compile.
contract RawDeployer {
    receive() external payable {}

    function deployWithValue(uint256 value) external returns (address deployed) {
        bytes memory code = type(SpectraToken).creationCode;
        assembly ("memory-safe") {
            deployed := create(value, add(code, 32), mload(code))
        }
    }
}

/// @notice Property tests that constrain the token algebraically rather than restating its code:
/// additivity and order independence of transfers, last-write-wins approvals, the exact boundary of
/// the "infinite" allowance, fuzzed callers and recipients, and the absence of any entry point
/// beyond the ERC-20 surface.
contract SpectraTokenPropertiesTest is Test {
    uint256 private constant SUPPLY = 10_000_000 * 10 ** 18;
    SpectraToken private token;
    address private deployer;

    function setUp() public {
        deployer = makeAddr("deployer");
        vm.prank(deployer);
        token = new SpectraToken();
    }

    // ---------------------------------------------------------------------------------------------
    // Supply and metadata pinned to the brief
    // ---------------------------------------------------------------------------------------------

    function test_SupplyIsExactlyTenMillionTokensInMinorUnits() public view {
        assertEq(token.totalSupply(), 10_000_000_000_000_000_000_000_000);
        assertEq(token.totalSupply(), 10_000_000 * 10 ** uint256(token.decimals()));
        assertEq(token.INITIAL_SUPPLY(), token.totalSupply());
        assertEq(token.balanceOf(deployer), token.totalSupply());
    }

    function test_MetadataIsIdenticalAcrossDeploymentsAndCallers() public {
        vm.prank(makeAddr("someone else"));
        SpectraToken second = new SpectraToken();
        assertEq(keccak256(bytes(token.name())), keccak256(bytes(second.name())));
        assertEq(keccak256(bytes(token.symbol())), keccak256(bytes(second.symbol())));
        assertEq(token.decimals(), second.decimals());
        assertEq(token.totalSupply(), second.totalSupply());
        assertEq(bytes(token.name()).length, bytes("Spectra IMD").length);
        assertEq(bytes(token.symbol()).length, bytes("SPECTRA").length);

        // Metadata reads are caller independent.
        vm.prank(makeAddr("random reader"));
        assertEq(token.name(), "Spectra IMD");
        vm.prank(makeAddr("random reader"));
        assertEq(token.symbol(), "SPECTRA");
    }

    function test_EachDeploymentMintsItsOwnSupplyWithoutSharingState() public {
        vm.prank(makeAddr("someone else"));
        SpectraToken second = new SpectraToken();
        assertEq(second.balanceOf(makeAddr("someone else")), SUPPLY);
        assertEq(second.balanceOf(deployer), 0);
        assertEq(token.balanceOf(makeAddr("someone else")), 0);
        assertEq(token.totalSupply() + second.totalSupply(), 2 * SUPPLY);
    }

    function test_ConstructorRefusesEther() public {
        RawDeployer raw = new RawDeployer();
        vm.deal(address(raw), 1 ether);
        address deployed = raw.deployWithValue(1 wei);
        assertEq(deployed, address(0), "non-payable constructor accepted ETH");
        assertEq(address(raw).balance, 1 ether, "ETH left the deployer on a failed creation");

        address ok = raw.deployWithValue(0);
        assertTrue(ok != address(0));
        assertEq(SpectraToken(ok).balanceOf(address(raw)), SUPPLY);
    }

    // ---------------------------------------------------------------------------------------------
    // No surface beyond ERC-20
    // ---------------------------------------------------------------------------------------------

    function test_EmptyCalldataIsRejected() public {
        (bool ok,) = address(token).call("");
        assertFalse(ok, "token has a receive or fallback");
        (ok,) = address(token).call(hex"00");
        assertFalse(ok, "token accepted a one byte payload");
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 2000
    function testFuzz_UnknownSelectorsRevertAndChangeNothing(bytes4 selector, bytes calldata payload) public {
        if (_isKnownSelector(selector)) return;
        uint256 balanceBefore = token.balanceOf(deployer);
        (bool ok,) = address(token).call(abi.encodePacked(selector, payload));
        assertFalse(ok, "an undeclared selector was reachable");
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(deployer), balanceBefore);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_KnownSelectorsNeverChangeSupply(uint8 selectorIndex, bytes calldata payload, address caller)
        public
    {
        bytes4 selector = _knownSelectors()[selectorIndex % 10];
        vm.prank(caller);
        (bool ok,) = address(token).call(abi.encodePacked(selector, payload));
        ok;
        assertEq(token.totalSupply(), SUPPLY, "a call on the ERC-20 surface changed the supply");
    }

    // ---------------------------------------------------------------------------------------------
    // Transfers: algebraic properties with fuzzed actors
    // ---------------------------------------------------------------------------------------------

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_TransferToAnyNonZeroAddressDeliversExactly(address to, uint256 amount) public {
        vm.assume(to != address(0));
        amount = bound(amount, 0, SUPPLY);
        uint256 toBefore = token.balanceOf(to);
        uint256 fromBefore = token.balanceOf(deployer);
        vm.prank(deployer);
        assertTrue(token.transfer(to, amount));
        if (to == deployer) {
            assertEq(token.balanceOf(deployer), SUPPLY);
        } else {
            assertEq(token.balanceOf(to), toBefore + amount);
            assertEq(token.balanceOf(deployer), fromBefore - amount);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_TwoTransfersEqualOneTransferOfTheSum(address to, uint256 a, uint256 b) public {
        vm.assume(to != address(0) && to != deployer);
        a = bound(a, 0, SUPPLY);
        b = bound(b, 0, SUPPLY - a);

        uint256 snapshot = vm.snapshotState();
        vm.startPrank(deployer);
        token.transfer(to, a);
        token.transfer(to, b);
        vm.stopPrank();
        uint256 splitTo = token.balanceOf(to);
        uint256 splitFrom = token.balanceOf(deployer);

        vm.revertToState(snapshot);
        vm.prank(deployer);
        token.transfer(to, a + b);
        assertEq(token.balanceOf(to), splitTo);
        assertEq(token.balanceOf(deployer), splitFrom);
        assertEq(splitTo + splitFrom, SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_TransferOrderDoesNotMatter(address x, address y, uint256 a, uint256 b) public {
        vm.assume(x != address(0) && y != address(0) && x != y && x != deployer && y != deployer);
        a = bound(a, 0, SUPPLY);
        b = bound(b, 0, SUPPLY - a);

        uint256 snapshot = vm.snapshotState();
        vm.startPrank(deployer);
        token.transfer(x, a);
        token.transfer(y, b);
        vm.stopPrank();
        uint256 xFirst = token.balanceOf(x);
        uint256 yFirst = token.balanceOf(y);

        vm.revertToState(snapshot);
        vm.startPrank(deployer);
        token.transfer(y, b);
        token.transfer(x, a);
        vm.stopPrank();
        assertEq(token.balanceOf(x), xFirst);
        assertEq(token.balanceOf(y), yFirst);
        assertEq(token.balanceOf(deployer), SUPPLY - a - b);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_RoundTripRestoresBothBalances(address other, uint256 amount) public {
        vm.assume(other != address(0) && other != deployer);
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        token.transfer(other, amount);
        vm.prank(other);
        token.transfer(deployer, amount);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(other), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_HolderWithoutSupplyCannotSendAnything(address holder, address to, uint256 amount) public {
        vm.assume(holder != deployer && holder != address(0) && to != address(0));
        amount = bound(amount, 1, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, holder, 0, amount));
        vm.prank(holder);
        token.transfer(to, amount);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_ExactlyOneWeiOverBalanceReverts(address holder, uint256 held) public {
        vm.assume(holder != address(0) && holder != deployer);
        held = bound(held, 0, SUPPLY - 1);
        vm.prank(deployer);
        token.transfer(holder, held);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, holder, held, held + 1));
        vm.prank(holder);
        token.transfer(deployer, held + 1);
        // The whole balance is still spendable afterwards.
        vm.prank(holder);
        assertTrue(token.transfer(deployer, held));
        assertEq(token.balanceOf(holder), 0);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    /// @dev The zero address is refused as a sender before its balance is even consulted, and as an
    /// approver before any allowance is written: nothing can be routed through it.
    function test_ZeroAddressCannotActAsSenderOrApprover() public {
        address to = makeAddr("to");
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(0)));
        vm.prank(address(0));
        token.transfer(to, 0);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        vm.prank(address(0));
        token.approve(to, 1);
        assertEq(token.allowance(address(0), to), 0);

        // Nor can anybody pull from it: the allowance check fails before the sender check.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, to, 0, 1));
        vm.prank(to);
        token.transferFrom(address(0), to, 1);
        assertEq(token.balanceOf(address(0)), 0);
    }

    function test_TokensSentToTheTokenContractAreUnrecoverable() public {
        vm.prank(deployer);
        assertTrue(token.transfer(address(token), 7 ether));
        assertEq(token.balanceOf(address(token)), 7 ether);
        // The contract has no function that moves its own balance: the only paths out are
        // transfer, which it never calls, and transferFrom, which needs an approval it never grants.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 7 ether));
        vm.prank(deployer);
        token.transferFrom(address(token), deployer, 7 ether);
        assertEq(token.balanceOf(address(token)), 7 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    // ---------------------------------------------------------------------------------------------
    // Approvals and delegated transfers
    // ---------------------------------------------------------------------------------------------

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_ApproveIsLastWriteWinsForAnyOwner(address owner, address spender, uint256 first, uint256 second)
        public
    {
        vm.assume(owner != address(0) && spender != address(0));
        vm.startPrank(owner);
        assertTrue(token.approve(spender, first));
        assertEq(token.allowance(owner, spender), first);
        assertTrue(token.approve(spender, second));
        vm.stopPrank();
        assertEq(token.allowance(owner, spender), second, "approve accumulated instead of replacing");
        // Approving is free of balance effects even for an owner that holds nothing.
        assertEq(token.balanceOf(spender), spender == deployer ? SUPPLY : 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_ApproveIsIdempotent(address spender, uint256 amount) public {
        vm.assume(spender != address(0));
        vm.startPrank(deployer);
        token.approve(spender, amount);
        token.approve(spender, amount);
        vm.stopPrank();
        assertEq(token.allowance(deployer, spender), amount);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_AllowanceIsDirectional(address owner, address spender, uint256 amount) public {
        vm.assume(owner != spender && spender != address(0) && owner != address(0));
        vm.prank(owner);
        token.approve(spender, amount);
        assertEq(token.allowance(owner, spender), amount);
        assertEq(token.allowance(spender, owner), 0, "approval leaked in the reverse direction");
    }

    function test_MaxMinusOneAllowanceIsFiniteAndDecrements() public {
        address spender = makeAddr("spender");
        vm.prank(deployer);
        token.approve(spender, type(uint256).max - 1);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, spender, 1));
        assertEq(token.allowance(deployer, spender), type(uint256).max - 2);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_InfiniteAllowanceSurvivesAnySpendSequence(uint256 a, uint256 b) public {
        address spender = makeAddr("spender");
        a = bound(a, 0, SUPPLY);
        b = bound(b, 0, SUPPLY - a);
        vm.prank(deployer);
        token.approve(spender, type(uint256).max);
        vm.startPrank(spender);
        token.transferFrom(deployer, spender, a);
        token.transferFrom(deployer, spender, b);
        vm.stopPrank();
        assertEq(token.allowance(deployer, spender), type(uint256).max);
        assertEq(token.balanceOf(spender), a + b);
        assertEq(token.balanceOf(deployer), SUPPLY - a - b);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_DelegatedTransferEqualsDirectTransfer(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != deployer);
        address spender = makeAddr("spender");
        vm.assume(to != spender);
        amount = bound(amount, 0, SUPPLY);

        uint256 snapshot = vm.snapshotState();
        vm.prank(deployer);
        token.transfer(to, amount);
        uint256 direct = token.balanceOf(to);

        vm.revertToState(snapshot);
        vm.prank(deployer);
        token.approve(spender, amount);
        vm.prank(spender);
        token.transferFrom(deployer, to, amount);
        assertEq(token.balanceOf(to), direct);
        assertEq(token.balanceOf(deployer), SUPPLY - amount);
        assertEq(token.balanceOf(spender), 0, "the spender kept part of a delegated transfer");
        assertEq(token.allowance(deployer, spender), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_SpenderCannotExceedAllowanceAcrossSeveralCalls(uint256 approved, uint256 first) public {
        address spender = makeAddr("spender");
        approved = bound(approved, 1, SUPPLY);
        first = bound(first, 0, approved);
        vm.prank(deployer);
        token.approve(spender, approved);
        vm.prank(spender);
        token.transferFrom(deployer, spender, first);
        uint256 remaining = approved - first;
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, remaining, remaining + 1)
        );
        vm.prank(spender);
        token.transferFrom(deployer, spender, remaining + 1);
        assertEq(token.balanceOf(spender), first);
        assertEq(token.allowance(deployer, spender), remaining);
    }

    function test_OwnerCannotSpendOwnBalanceThroughTransferFromWithoutSelfApproval() public {
        address to = makeAddr("to");
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1));
        vm.prank(deployer);
        token.transferFrom(deployer, to, 1);

        vm.startPrank(deployer);
        token.approve(deployer, 1);
        assertTrue(token.transferFrom(deployer, to, 1));
        vm.stopPrank();
        assertEq(token.balanceOf(to), 1);
        assertEq(token.allowance(deployer, deployer), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_AllowanceAboveBalanceDoesNotCreateTokens(address holder, uint256 held, uint256 approved) public {
        vm.assume(holder != address(0) && holder != deployer);
        address spender = makeAddr("spender");
        vm.assume(holder != spender);
        held = bound(held, 0, SUPPLY - 1);
        approved = bound(approved, held + 1, type(uint256).max);
        vm.prank(deployer);
        token.transfer(holder, held);
        vm.prank(holder);
        token.approve(spender, approved);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, holder, held, held + 1));
        vm.prank(spender);
        token.transferFrom(holder, spender, held + 1);

        vm.prank(spender);
        assertTrue(token.transferFrom(holder, spender, held));
        assertEq(token.balanceOf(spender), held);
        assertEq(token.balanceOf(holder), 0);
        assertEq(token.allowance(holder, spender), approved == type(uint256).max ? approved : approved - held);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_SpendingAllowanceEmitsTransferButNoApprovalEvent() public {
        address spender = makeAddr("spender");
        vm.prank(deployer);
        token.approve(spender, 3 ether);
        vm.recordLogs();
        vm.prank(spender);
        token.transferFrom(deployer, spender, 1 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "transferFrom emitted more than the Transfer event");
        assertEq(logs[0].topics[0], IERC20.Transfer.selector);
        assertEq(address(uint160(uint256(logs[0].topics[1]))), deployer);
        assertEq(address(uint160(uint256(logs[0].topics[2]))), spender);
        assertEq(abi.decode(logs[0].data, (uint256)), 1 ether);
        // Integrations must read allowance() rather than wait for an Approval event.
        assertEq(token.allowance(deployer, spender), 2 ether);
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------

    function _knownSelectors() private pure returns (bytes4[10] memory s) {
        s[0] = IERC20Metadata.name.selector;
        s[1] = IERC20Metadata.symbol.selector;
        s[2] = IERC20Metadata.decimals.selector;
        s[3] = IERC20.totalSupply.selector;
        s[4] = IERC20.balanceOf.selector;
        s[5] = IERC20.transfer.selector;
        s[6] = IERC20.allowance.selector;
        s[7] = IERC20.approve.selector;
        s[8] = IERC20.transferFrom.selector;
        s[9] = bytes4(keccak256("INITIAL_SUPPLY()"));
    }

    function _isKnownSelector(bytes4 selector) private pure returns (bool) {
        bytes4[10] memory s = _knownSelectors();
        for (uint256 i; i < s.length; ++i) {
            if (s[i] == selector) return true;
        }
        return false;
    }
}
