// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SpectraToken} from "../src/SpectraToken.sol";

/// @notice Drives the token with an open set of actors: a fixed core of holders plus any address
/// the fuzzer invents, the token contract itself as a sink, and a share of calls that must fail.
/// Every successful call is mirrored in a ghost model; every call that must fail is checked to
/// fail with the exact ERC-6093 error and to leave the state untouched.
contract OpenTokenHandler is Test {
    uint256 public constant SUPPLY = 10_000_000 * 10 ** 18;
    uint256 private constant MAX_TRACKED = 64;

    SpectraToken public immutable token;
    address public immutable deployer;

    address[] public actors;
    mapping(address => bool) public isActor;
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;

    // Ghost accounting over the whole campaign.
    uint256 public ghostVolume; // every unit that moved through transfer or transferFrom
    uint256 public ghostSinkBalance; // what the token contract holds; may only grow
    uint256 public ghostSuccessfulCalls;
    uint256 public ghostRejectedCalls;
    uint256 public ghostFreshActors;

    constructor(SpectraToken token_, address deployer_, address[] memory core) {
        token = token_;
        deployer = deployer_;
        _track(deployer_);
        for (uint256 i; i < core.length; ++i) {
            _track(core[i]);
        }
        _track(address(token_));
        expectedBalance[deployer_] = SUPPLY;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    // ---------------------------------------------------------------------------------------------
    // Calls that must succeed
    // ---------------------------------------------------------------------------------------------

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 rawAmount) external {
        address from = _sender(fromSeed);
        address to = _actor(toSeed);
        uint256 amount = bound(rawAmount, 0, expectedBalance[from]);
        _modelTransfer(from, to, amount);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        ++ghostSuccessfulCalls;
    }

    /// @dev Sends to an address the fuzzer invents, widening the tracked set.
    function transferToFresh(uint256 fromSeed, address to, uint256 rawAmount) external {
        if (to == address(0)) to = address(1);
        if (!isActor[to]) {
            if (actors.length >= MAX_TRACKED) return;
            _track(to);
            ++ghostFreshActors;
        }
        address from = _sender(fromSeed);
        uint256 amount = bound(rawAmount, 0, expectedBalance[from]);
        _modelTransfer(from, to, amount);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        ++ghostSuccessfulCalls;
    }

    /// @dev Tokens sent to the token contract are tracked like any balance and never come back.
    function sendToSink(uint256 fromSeed, uint256 rawAmount) external {
        address from = _sender(fromSeed);
        uint256 amount = bound(rawAmount, 0, expectedBalance[from]);
        _modelTransfer(from, address(token), amount);
        vm.prank(from);
        assertTrue(token.transfer(address(token), amount));
        ++ghostSuccessfulCalls;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner = _sender(ownerSeed);
        address spender = _actor(spenderSeed);
        expectedAllowance[owner][spender] = amount;
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        ++ghostSuccessfulCalls;
    }

    function transferFrom(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 rawAmount) external {
        address spender = _sender(spenderSeed);
        address from = _sender(fromSeed);
        address to = _actor(toSeed);
        uint256 approved = expectedAllowance[from][spender];
        uint256 available = expectedBalance[from] < approved ? expectedBalance[from] : approved;
        uint256 amount = bound(rawAmount, 0, available);
        if (approved != type(uint256).max) expectedAllowance[from][spender] -= amount;
        _modelTransfer(from, to, amount);
        vm.prank(spender);
        assertTrue(token.transferFrom(from, to, amount));
        ++ghostSuccessfulCalls;
    }

    // ---------------------------------------------------------------------------------------------
    // Calls that must fail, and must fail cleanly
    // ---------------------------------------------------------------------------------------------

    function transferAboveBalance(uint256 fromSeed, uint256 toSeed, uint256 rawAmount) external {
        address from = _sender(fromSeed);
        address to = _actor(toSeed);
        uint256 held = expectedBalance[from];
        uint256 amount = bound(rawAmount, held + 1, type(uint256).max);
        uint256 toBefore = token.balanceOf(to);
        vm.prank(from);
        try token.transfer(to, amount) {
            assertTrue(false, "transfer above balance succeeded");
        } catch (bytes memory reason) {
            assertEq(reason, abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, held, amount));
        }
        assertEq(token.balanceOf(from), held);
        assertEq(token.balanceOf(to), toBefore);
        ++ghostRejectedCalls;
    }

    function transferToZeroAddress(uint256 fromSeed, uint256 rawAmount) external {
        address from = _sender(fromSeed);
        uint256 amount = bound(rawAmount, 0, expectedBalance[from]);
        vm.prank(from);
        try token.transfer(address(0), amount) {
            assertTrue(false, "transfer to the zero address succeeded");
        } catch (bytes memory reason) {
            assertEq(reason, abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        }
        assertEq(token.balanceOf(from), expectedBalance[from]);
        ++ghostRejectedCalls;
    }

    function approveZeroSpender(uint256 ownerSeed, uint256 amount) external {
        address owner = _sender(ownerSeed);
        vm.prank(owner);
        try token.approve(address(0), amount) {
            assertTrue(false, "approve of the zero spender succeeded");
        } catch (bytes memory reason) {
            assertEq(reason, abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        }
        assertEq(token.allowance(owner, address(0)), 0);
        ++ghostRejectedCalls;
    }

    function transferFromAboveAllowance(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 rawAmount)
        external
    {
        address spender = _sender(spenderSeed);
        address from = _sender(fromSeed);
        address to = _actor(toSeed);
        uint256 approved = expectedAllowance[from][spender];
        if (approved == type(uint256).max) return; // nothing exceeds an infinite allowance
        uint256 amount = bound(rawAmount, approved + 1, type(uint256).max);
        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);
        vm.prank(spender);
        try token.transferFrom(from, to, amount) {
            assertTrue(false, "transferFrom above allowance succeeded");
        } catch (bytes memory reason) {
            assertEq(
                reason,
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, approved, amount)
            );
        }
        assertEq(token.allowance(from, spender), approved, "a failed transferFrom consumed allowance");
        assertEq(token.balanceOf(from), fromBefore);
        assertEq(token.balanceOf(to), toBefore);
        ++ghostRejectedCalls;
    }

    function transferFromAboveBalance(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 rawAmount)
        external
    {
        address spender = _sender(spenderSeed);
        address from = _sender(fromSeed);
        address to = _actor(toSeed);
        uint256 held = expectedBalance[from];
        uint256 approved = expectedAllowance[from][spender];
        if (approved <= held) return; // the allowance check fires first; covered above
        uint256 amount = bound(rawAmount, held + 1, approved);
        vm.prank(spender);
        try token.transferFrom(from, to, amount) {
            assertTrue(false, "transferFrom above balance succeeded");
        } catch (bytes memory reason) {
            assertEq(reason, abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, held, amount));
        }
        assertEq(token.allowance(from, spender), approved, "a failed transferFrom consumed allowance");
        assertEq(token.balanceOf(from), held);
        ++ghostRejectedCalls;
    }

    /// @dev The deployer is the only address with any plausible claim to privilege. None exists.
    function deployerTriesPrivilegedCall(uint256 which, uint256 targetSeed, uint256 amount) external {
        address target = _actor(targetSeed);
        bytes[8] memory calls = [
            abi.encodeWithSignature("mint(address,uint256)", target, amount),
            abi.encodeWithSignature("burn(uint256)", amount),
            abi.encodeWithSignature("burnFrom(address,uint256)", target, amount),
            abi.encodeWithSignature("pause()"),
            abi.encodeWithSignature("blacklist(address)", target),
            abi.encodeWithSignature("freeze(address)", target),
            abi.encodeWithSignature("seize(address)", target),
            abi.encodeWithSignature("transferOwnership(address)", target)
        ];
        vm.prank(deployer);
        (bool ok,) = address(token).call(calls[which % calls.length]);
        assertFalse(ok, "the deployer reached a privileged function");
        ++ghostRejectedCalls;
    }

    function strangerCallsUnknownSelector(bytes4 selector, bytes calldata payload, uint256 callerSeed) external {
        if (_isErc20Selector(selector)) return;
        vm.prank(_actor(callerSeed));
        (bool ok,) = address(token).call(abi.encodePacked(selector, payload));
        assertFalse(ok, "an undeclared selector was reachable");
        ++ghostRejectedCalls;
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % actors.length];
    }

    /// @dev Any tracked address except the token contract, which nothing can make call itself.
    function _sender(uint256 seed) private view returns (address) {
        uint256 index = seed % actors.length;
        if (actors[index] == address(token)) index = (index + 1) % actors.length;
        return actors[index];
    }

    function _track(address account) private {
        if (isActor[account]) return;
        isActor[account] = true;
        actors.push(account);
    }

    function _modelTransfer(address from, address to, uint256 amount) private {
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
        if (to == address(token)) ghostSinkBalance += amount;
        ghostVolume += amount;
    }

    function _isErc20Selector(bytes4 selector) private pure returns (bool) {
        return selector == IERC20Metadata.name.selector || selector == IERC20Metadata.symbol.selector
            || selector == IERC20Metadata.decimals.selector || selector == IERC20.totalSupply.selector
            || selector == IERC20.balanceOf.selector || selector == IERC20.transfer.selector
            || selector == IERC20.allowance.selector || selector == IERC20.approve.selector
            || selector == IERC20.transferFrom.selector || selector == bytes4(keccak256("INITIAL_SUPPLY()"));
    }
}

contract SpectraTokenOpenInvariantTest is Test {
    uint256 private constant SUPPLY = 10_000_000 * 10 ** 18;
    SpectraToken private token;
    OpenTokenHandler private handler;
    address private deployer;

    function setUp() public {
        deployer = makeAddr("deployer");
        vm.prank(deployer);
        token = new SpectraToken();

        address[] memory core = new address[](5);
        for (uint256 i; i < core.length; ++i) {
            core[i] = makeAddr(string.concat("core holder ", vm.toString(i)));
        }
        handler = new OpenTokenHandler(token, deployer, core);

        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = OpenTokenHandler.transfer.selector;
        selectors[1] = OpenTokenHandler.transferToFresh.selector;
        selectors[2] = OpenTokenHandler.sendToSink.selector;
        selectors[3] = OpenTokenHandler.approve.selector;
        selectors[4] = OpenTokenHandler.transferFrom.selector;
        selectors[5] = OpenTokenHandler.transferAboveBalance.selector;
        selectors[6] = OpenTokenHandler.transferToZeroAddress.selector;
        selectors[7] = OpenTokenHandler.approveZeroSpender.selector;
        selectors[8] = OpenTokenHandler.transferFromAboveAllowance.selector;
        selectors[9] = OpenTokenHandler.transferFromAboveBalance.selector;
        selectors[10] = OpenTokenHandler.deployerTriesPrivilegedCall.selector;
        selectors[11] = OpenTokenHandler.strangerCallsUnknownSelector.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_TotalSupplyNeverMoves() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_TrackedBalancesSumToSupplyAndMatchModel() public view {
        uint256 count = handler.actorCount();
        uint256 sum;
        for (uint256 i; i < count; ++i) {
            address actor = handler.actors(i);
            uint256 balance = token.balanceOf(actor);
            assertEq(balance, handler.expectedBalance(actor), "a balance drifted from the model");
            sum += balance;
        }
        assertEq(sum, SUPPLY, "tokens appeared or vanished outside the tracked set");
        assertEq(token.balanceOf(address(0)), 0);
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_TokenContractBalanceOnlyGrows() public view {
        assertEq(token.balanceOf(address(token)), handler.ghostSinkBalance(), "the sink balance changed");
        assertLe(handler.ghostSinkBalance(), SUPPLY);
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_AllowancesMatchModelForEveryPair() public view {
        uint256 count = handler.actorCount();
        for (uint256 i; i < count; ++i) {
            address owner = handler.actors(i);
            for (uint256 j; j < count; ++j) {
                address spender = handler.actors(j);
                assertEq(token.allowance(owner, spender), handler.expectedAllowance(owner, spender));
            }
            assertEq(token.allowance(owner, address(0)), 0);
        }
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_NoHolderExceedsSupplyAndVolumeIsBoundedByCalls() public view {
        uint256 count = handler.actorCount();
        for (uint256 i; i < count; ++i) {
            assertLe(token.balanceOf(handler.actors(i)), SUPPLY);
        }
        // Each successful call moves at most the whole supply, so cumulative volume is bounded.
        assertLe(handler.ghostVolume(), handler.ghostSuccessfulCalls() * SUPPLY);
    }
}
