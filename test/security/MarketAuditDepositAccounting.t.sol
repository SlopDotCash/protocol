// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SpotLiquidityVault} from "../../src/core/SpotLiquidityVault.sol";
import {ISpotLiquidityVault} from "../../src/interfaces/ISpotLiquidityVault.sol";

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {UmiaMarketCore} from "../../src/core/UmiaMarketCore.sol";
import {IUmiaMarketCore} from "../../src/interfaces/IUmiaMarketCore.sol";
import {IUmiaHub} from "../../src/interfaces/IUmiaHub.sol";

contract MarketAuditTaxToken is ERC20 {
    address public taxedRecipient;
    constructor() ERC20("Taxed", "TAX") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setTaxedRecipient(address to) external {
        taxedRecipient = to;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && to == taxedRecipient) {
            super._update(from, address(0), amount / 10);
            amount -= amount / 10;
        }
        super._update(from, to, amount);
    }
}

contract MarketAuditDepositHub {
    address internal token;

    constructor(address token_) {
        token = token_;
    }

    function ventureMoneyTokenById(uint256) external view returns (address) {
        return token;
    }

    function ventureTokenById(uint256) external view returns (address) {
        return token;
    }
}

contract MarketAuditDepositCore is UmiaMarketCore {
    function seed(address hub) external {
        HUB = IUmiaHub(hub);
        _markets[1].id = 1;
        _markets[1].ventureId = 1;
        _markets[1].tradingStart = uint64(block.timestamp);
        _markets[1].tradingEnd = uint64(block.timestamp + 1 days);
        _markets[1].proposalIds.push(1);
    }
}

contract MarketAuditDepositAccountingTest is Test {
    MarketAuditTaxToken internal token;
    MarketAuditDepositCore internal core;

    function setUp() public {
        token = new MarketAuditTaxToken();
        core = new MarketAuditDepositCore();
        core.seed(address(new MarketAuditDepositHub(address(token))));
        token.mint(address(this), 1000);
        token.mint(address(core), 1000); // Another market's escrow must remain untouched.
        token.approve(address(core), type(uint256).max);
    }

    function test_taxedMoneySplitRejectsUnbackedCreditAndPreservesOtherEscrow() public {
        token.setTaxedRecipient(address(core));
        vm.expectRevert(IUmiaMarketCore.InvariantViolation.selector);
        core.split(1, 0, 100);
        assertEq(token.balanceOf(address(core)), 1000);
        assertEq(token.balanceOf(address(this)), 1000);
        assertEq(core.balanceOf(address(this), core.getVirtualMoneyId(1)), 0);
    }

    function test_taxedVentureSplitRejectsUnbackedCredit() public {
        token.setTaxedRecipient(address(core));
        vm.expectRevert(IUmiaMarketCore.InvariantViolation.selector);
        core.split(1, 100, 0);
        assertEq(token.balanceOf(address(core)), 1000);
    }

    function test_exactReceiptRetainsSplitMergeConservation() public {
        core.split(1, 0, 100);
        core.merge(1, 0, 100);
        assertEq(token.balanceOf(address(core)), 1000);
        assertEq(token.balanceOf(address(this)), 1000);
    }
}

contract MarketAuditVaultVenture {
    address public token;
    address public moneyToken;

    constructor(address token_, address money_) {
        token = token_;
        moneyToken = money_;
    }
}

contract MarketAuditReceiptVault is SpotLiquidityVault {
    constructor(address venture_, address manager_)
        SpotLiquidityVault(address(1), venture_, manager_, address(2), 3000, 60)
    {
        isPoolInitialized = true;
        totalShares = 1000;
        shareBalance[address(0xBEEF)] = 1000;
    }
}

contract MarketAuditVaultDepositAccountingTest is Test {
    function test_taxedDepositCannotDiluteExistingIdleAssetShares() public {
        MarketAuditTaxToken ventureToken = new MarketAuditTaxToken();
        MarketAuditTaxToken moneyToken = new MarketAuditTaxToken();
        address manager = address(0xCAFE);
        MarketAuditReceiptVault vault = new MarketAuditReceiptVault(
            address(new MarketAuditVaultVenture(address(ventureToken), address(moneyToken))), manager
        );
        // Model a bootstrapped vault with idle assets and no remaining in-pool position.
        vm.mockCall(manager, abi.encodeWithSignature("extsload(bytes32,uint256)"), abi.encode(new bytes32[](3)));
        ventureToken.mint(address(vault), 1000);
        moneyToken.mint(address(vault), 1000);
        ventureToken.mint(address(this), 100);
        moneyToken.mint(address(this), 100);
        ventureToken.approve(address(vault), 100);
        moneyToken.approve(address(vault), 100);
        moneyToken.setTaxedRecipient(address(vault));
        vm.expectRevert(ISpotLiquidityVault.InvalidAmount.selector);
        vault.deposit(100, 100, 0, address(this));
        assertEq(vault.totalShares(), 1000);
        assertEq(vault.shareBalance(address(this)), 0);
        assertEq(moneyToken.balanceOf(address(vault)), 1000);
        assertEq(ventureToken.balanceOf(address(vault)), 1000);
    }
}
