// SPDX-License-Identifier:MIT
pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig config;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;
    address wbtc;

    address public USER = makeAddr("user");
    address public LIQUIDATOR = makeAddr("liquidator");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant PRECISION = 1e18;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc, ) = config
            .activeNetworkConfig();
        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
        ERC20Mock(wbtc).mint(USER, STARTING_ERC20_BALANCE);
    }

    ///////////////////////
    // Constructor Tests //
    //////////////////////
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(
            DSCEngine
                .DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength
                .selector
        );
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    ///////////////////////////
    // Public function Tests //
    //////////////////////////
    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18;
        // 15e18 * 2000/ETH = 30,000e18;
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = dsce.getUsdValue(weth, ethAmount);
        assertEq(expectedUsd, actualUsd);
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 usdAmount = 100 ether;
        // $2,000 / ETH, $100
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = dsce.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedWeth, actualWeth);
    }

    function testGetAccountInfo() public {
        (uint256 totalDscMintedBefore, ) = dsce.getAccountInformation(USER);

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();

        (uint256 totalDscMintedAfter, ) = dsce.getAccountInformation(USER);
        assertEq(totalDscMintedBefore, totalDscMintedAfter);
    }

    function testGetAccountCollateralValue() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        ERC20Mock(wbtc).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        dsce.depositCollateral(wbtc, AMOUNT_COLLATERAL);
        vm.stopPrank();

        // uint256
        uint256 totalValueOfCollateralInUsdAfter = dsce
            .getAccountCollateralValue(USER);

        (, uint256 expectedValueOfCollateral) = dsce.getAccountInformation(
            USER
        );
        assertEq(totalValueOfCollateralInUsdAfter, expectedValueOfCollateral);
    }

    /////////////////////////////
    // Deposit Collateral Test //
    ////////////////////////////
    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock(
            "RAN",
            "RAN",
            USER,
            AMOUNT_COLLATERAL
        );
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        dsce.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetAccountInfo()
        public
        depositedCollateral
    {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce
            .getAccountInformation(USER);
        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositAmount = dsce.getTokenAmountFromUsd(
            weth,
            collateralValueInUsd
        );
        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(AMOUNT_COLLATERAL, expectedDepositAmount);
    }

    function testDepositCollateralTransferFailsWithMock() public {
        uint256 amount = 100e18;

        // Prepare calldata
        bytes memory transferFromCall = abi.encodeWithSelector(
            IERC20.transferFrom.selector,
            USER,
            address(dsce),
            amount
        );

        // Mock the return value to be false
        vm.mockCall(
            address(weth), // Target contract
            transferFromCall, // Calldata
            abi.encode(false) // Return value
        );

        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        dsce.depositCollateral(address(weth), amount);
        vm.stopPrank();
    }

    ///////////////////////////
    // Redeem Colateral Test //
    //////////////////////////
    function testingReedemCollateralBalanceUpdateBeforeAndAfter()
        public
        depositedCollateral
    {
        (, uint256 collateralValueInUsdBefore) = dsce.getAccountInformation(
            USER
        );
        //Usd To Eth balance
        uint256 balanceBeforeRedeem = dsce.getTokenAmountFromUsd(
            weth,
            collateralValueInUsdBefore
        );

        // START PRANK HERE TOO!
        vm.startPrank(USER);
        uint256 redeemAmount = 1 ether;
        dsce.redemCollateral(weth, redeemAmount);
        vm.stopPrank();

        (, uint256 collateralValueInUsdAfter) = dsce.getAccountInformation(
            USER
        );
        //Usd To Eth balance
        uint256 balanceAfterRedeem = dsce.getTokenAmountFromUsd(
            weth,
            collateralValueInUsdAfter
        );

        assertEq(balanceBeforeRedeem, balanceAfterRedeem + redeemAmount);
    }

    function testingRedeemRevertIfWeTryToRedeemZeroAmount()
        public
        depositedCollateral
    {
        vm.startPrank(USER);
        uint256 redeemAmount = 0 ether;
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.redemCollateral(weth, redeemAmount);
        vm.stopPrank();
    }

    ///////////////////
    // Mint Dsc Test //
    //////////////////
    function testDscTokenValueBeforeAndAfterMint() public depositedCollateral {
        (uint256 dscMintedBefore, uint256 amount) = dsce.getAccountInformation(
            USER
        );

        vm.startPrank(USER);
        uint256 amountMinted = (amount * LIQUIDATION_THRESHOLD) /
            LIQUIDATION_PRECISION; // This is the maximum we can mint. After this, health factor will broke
        dsce.mintDsc(amountMinted);
        vm.stopPrank();

        (uint256 dscMintedAfter, ) = dsce.getAccountInformation(USER);

        assertEq(dscMintedAfter, (dscMintedBefore + amountMinted));
    }

    function testRevertIfMintMoreThenHealthFactor() public depositedCollateral {
        (, uint256 amount) = dsce.getAccountInformation(USER);

        uint256 maximumMintValue = (amount * LIQUIDATION_THRESHOLD) /
            LIQUIDATION_PRECISION; // This is the maximum we can mint. After this, health factor will broke
        uint256 breakHealthFactorValue = 1; // breaking health factor by adding just 1  number
        uint256 expectedHealthFactor = (maximumMintValue * PRECISION) /
            (maximumMintValue + breakHealthFactorValue); // This is purely maths please see _healthFactor function in DSCEngine.sol

        vm.startPrank(USER);
        vm.expectRevert(
            abi.encodeWithSelector(
                DSCEngine.DSCEngine__BreakHealthFactor.selector,
                expectedHealthFactor
            )
        );
        dsce.mintDsc(maximumMintValue + breakHealthFactorValue);
        vm.stopPrank();
    }

    function testMintDscRevertsIfMintFails() public depositedCollateral {
        uint256 amountToMint = 10e18;

        // Prepare calldata for i_dsc.mint(msg.sender, amountToMint)
        bytes memory mintCall = abi.encodeWithSelector(
            dsc.mint.selector,
            USER,
            amountToMint
        );

        // Mock the DSC contract to return false for this call
        vm.mockCall(
            address(dsc), // Fake the dsc contract response
            mintCall, // Match mint(user, amount)
            abi.encode(false) // Force return value to be false
        );

        vm.startPrank(USER);

        vm.expectRevert(DSCEngine.DSCEngine__MintFailed.selector);
        dsce.mintDsc(amountToMint);
        vm.stopPrank();
    }

    ///////////////////
    // Burn Dsc Test //
    //////////////////
    function testDscTokenValueAferBurn() public depositedCollateral {
        uint256 dummyAmountMinted = 4e18;
        uint256 dummyAmountBurned = 2e18;

        vm.startPrank(USER);
        dsc.approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.mintDsc(dummyAmountMinted);
        (uint dscLeftBeforeBurn, ) = dsce.getAccountInformation(USER);
        dsce.burnDsc(dummyAmountBurned);
        vm.stopPrank();

        (uint dscLeftAfterBurn, ) = dsce.getAccountInformation(USER);
        assertEq(dscLeftAfterBurn, (dscLeftBeforeBurn - dummyAmountBurned));
    }

    function testBurningZeroAmount() public depositedCollateral {
        uint256 dummyAmountMinted = 4e18;
        uint256 dummyAmountBurned = 0;

        vm.startPrank(USER);
        dsc.approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.mintDsc(dummyAmountMinted);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.burnDsc(dummyAmountBurned);
        vm.stopPrank();
    }

    //////////////////////
    // Liquidation Test //
    //////////////////////
    function testLiquidationWorksAfterPriceDrops() public depositedCollateral {
        uint256 dummyAmountMinted = 4e18;

        vm.startPrank(USER);
        dsce.mintDsc(dummyAmountMinted);

        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        dsce.liquidate(weth, USER, dummyAmountMinted);
        vm.stopPrank();
    }

    function testLiquidateSucceedsWhenHealthFactorIsBroken()
        public
        depositedCollateral
    {
        uint256 dummyAmountMinted = 9000e18;

        vm.startPrank(USER);
        dsce.mintDsc(dummyAmountMinted);
        vm.stopPrank();

        // 🎯 MOCK PRICE DROP to make user liquidatable
        // Original price is something like $2000e8, let's mock it down to $1000e8
        int256 badPrice = 1000e8;
        bytes memory priceCall = abi.encodeWithSelector(
            AggregatorV3Interface.latestRoundData.selector
        );

        vm.mockCall( // These mock calls are written keeping src/libraries/oracleLib.sol file in mind
            address(ethUsdPriceFeed),
            priceCall,
            abi.encode(1, badPrice, block.timestamp, block.timestamp, 1) // ✅ updatedAt is fresh
        );

        // Now the user’s health factor is broken
        // LIQUIDATOR will liquidate USER
        vm.startPrank(LIQUIDATOR);
        deal(address(dsc), LIQUIDATOR, dummyAmountMinted); // mint DSC for liquidation
        dsc.approve(address(dsce), dummyAmountMinted);

        dsce.liquidate(address(weth), USER, dummyAmountMinted); // 🔥 this should now succeed
        vm.stopPrank();
    }

    function testLiquidateRevertsWhenHealthFactorNotOk()
        public
        depositedCollateral
    {
        uint256 dummyAmountMinted = 9000e18;

        vm.startPrank(USER);
        dsce.mintDsc(dummyAmountMinted);
        vm.stopPrank();

        // 🎯 MOCK PRICE DROP to make user liquidatable
        // Original price is something like $2000e8, let's mock it down to $1000e8
        int256 badPrice = 1000e8;
        bytes memory priceCall = abi.encodeWithSelector(
            AggregatorV3Interface.latestRoundData.selector
        );

        vm.mockCall(
            address(ethUsdPriceFeed),
            priceCall,
            abi.encode(1, badPrice, block.timestamp, block.timestamp, 1) // ✅ updatedAt is fresh
        );

        // Now the user’s health factor is broken
        // LIQUIDATOR will liquidate USER
        uint256 lessAmountSoHealthFactorNotImproved = 1e16;
        vm.startPrank(LIQUIDATOR);
        deal(address(dsc), LIQUIDATOR, lessAmountSoHealthFactorNotImproved); // mint DSC for liquidation
        dsc.approve(address(dsce), lessAmountSoHealthFactorNotImproved);

        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorNotImproved.selector);
        dsce.liquidate(
            address(weth),
            USER,
            lessAmountSoHealthFactorNotImproved
        );
        vm.stopPrank();
    }

    ////////////////////////
    // Health Factor Test //
    ///////////////////////
    function testHealthFactor() public depositedCollateral {
        uint256 healthFactorBeforeMint = dsce.getHealthFactor(USER);

        vm.startPrank(USER);
        uint256 dummyAmountMintForTestingHealthFactor = 2e18;
        dsce.mintDsc(dummyAmountMintForTestingHealthFactor);
        vm.stopPrank();

        uint256 healthFactorAfterMint = dsce.getHealthFactor(USER);
        assert(healthFactorBeforeMint > healthFactorAfterMint);
    }

    function testHealthFactorMax() public depositedCollateral {
        uint256 healthFactorMax = dsce.getHealthFactor(USER);

        assert(healthFactorMax == type(uint256).max);
    }

    /////////////////////////////////
    // Redeem + Burn together Test //
    ////////////////////////////////

    function testReedemCollateralForDsc() public depositedCollateral {
        uint256 dummyAmountToMint = 4e18;
        (, uint256 collateralValueInUsdBefore) = dsce.getAccountInformation(
            USER
        );

        vm.startPrank(USER);
        dsce.mintDsc(dummyAmountToMint);
        dsc.approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.reedemCollateralForDsc(weth, AMOUNT_COLLATERAL, dummyAmountToMint);
        vm.stopPrank();

        (, uint256 collateralValueInUsdAfter) = dsce.getAccountInformation(
            USER
        );
        console.log(collateralValueInUsdAfter);
        console.log(collateralValueInUsdBefore);
    }

    //////////////////////////////////
    // Deposit + Burn together Test //
    /////////////////////////////////
    function testDepositCollateralAndMintDsc() public {
        uint dummyMint = 4e18;
        (uint256 dscMintedBefore, uint256 collateralAmountBefore) = dsce
            .getAccountInformation(USER);

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, dummyMint);
        vm.stopPrank();

        (uint256 dscMintedAfter, uint256 collateralAmountAfter) = dsce
            .getAccountInformation(USER);

        assert(dscMintedBefore < dscMintedAfter);
        assert(collateralAmountBefore < collateralAmountAfter);
    }
}
