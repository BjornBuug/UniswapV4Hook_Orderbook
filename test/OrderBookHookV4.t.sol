// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {WETH} from "solmate/src/tokens/WETH.sol";

import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

// This library allows for transferring and holding native tokens and ERC20 tokens
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";

// Contains hooks
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

// To get SquareRoot price for a Swap.
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

import {OrderBookHookV4} from "../src/OrderBookHookV4.sol";

// HookMiner to allow for minitng/deploying new Hook address based on it Flag
import {HookMiner} from "./utils/HookMiner.sol";

// contract that match the limit order
import {MatchingEngine} from "@standardweb3/exchange/MatchingEngine.sol";

// Contract to create a orderbook factory
import {OrderbookFactory} from "@standardweb3/exchange/orderbooks/OrderbookFactory.sol";

import {Helpers} from "./utils/Helpers.sol";

contract TestOrderBookHookV4 is Test, Deployers, Helpers {
    using CurrencyLibrary for Currency;

    MockERC20 UniToken;

    // wrap the ETH as currency type

    Currency tokenCurrency;

    // instance of the hook contract to test
    OrderBookHookV4 orderbookHook;

    address public trader1;
    address public admin;
    address[] public users;

    function setUp() public {
        users = Helpers.createUsers(4);
        trader1 = users[0];
        admin = users[1];
        vm.label(trader1, "Trader1");
        vm.label(admin, "Admin");
        vm.label(address(address(this)), "Test Contract");

        // Deploy the Wrapped ETH
        WETH weth = new WETH();

        // 1- Deploy the matching Engine and connect with the orderbook factory
        //----------------------------------------------------------------------
        // NOTE: address(this) has a admin role
        // deploy Orderbookfactory contract.
        OrderbookFactory orderBookFactory = new OrderbookFactory();

        // deploy matchineEngineFactory contract
        MatchingEngine matchingEngine = new MatchingEngine();

        // Initilize the matching Engine
        matchingEngine.initialize(
            address(orderBookFactory),
            address(admin),
            address(weth)
        );

        // Initilize the orderbook
        orderBookFactory.initialize(address(matchingEngine));
        // --------------------------------------------------------------

        // 2. Deploy PoolManager and RoutersContracts

        deployFreshManagerAndRouters();

        // Deploy ERC20 tokens
        UniToken = new MockERC20("UNISWAP", "UNI", 18);

        // wrap the tokens to currency type
        tokenCurrency = Currency.wrap(address(UniToken));
        Currency ethCurrency = Currency.wrap(address(0));

        UniToken.mint(address(this), 1_000 ether);
        UniToken.mint(trader1, 1_0000 ether);

        // --------------------------------------------------------------

        // 3- Deploy the hook to an address with the correct Flag used inside the hook contract
        // Combine flags using bitwise OR "|"
        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            )
        );

        bytes memory constructorArgs = abi.encode(
            manager,
            address(matchingEngine),
            address(weth)
        );

        // bytes memory constructorArgs = abi.encode(manager);

        deployCodeTo(
            "OrderBookHookV4.sol:OrderBookHookV4",
            constructorArgs,
            flags
        );

        orderbookHook = OrderBookHookV4(payable(flags));

        // Approve Max amount of UniToken to be spend by swap router and modifyliquidity router
        // address(this) approval
        UniToken.approve(address(swapRouter), type(uint256).max);
        UniToken.approve(address(modifyLiquidityRouter), type(uint256).max);
        UniToken.approve(address(matchingEngine), type(uint256).max);

        // Traders Approval
        vm.startPrank(trader1);
        UniToken.approve(address(swapRouter), type(uint256).max);
        UniToken.approve(address(modifyLiquidityRouter), type(uint256).max);
        UniToken.approve(address(matchingEngine), type(uint256).max);
        vm.stopPrank();

        // // Initilize a pool
        // (key, ) = initPool(
        //     ethCurrency,
        //     tokenCurrency,
        //     orderbookHook,
        //     3000,
        //     SQRT_PRICE_1_1,
        //     ZERO_BYTES
        // );

        // // add the above pair in the matching engine contract
        // matchingEngine.addPair(
        //     address(weth), // base
        //     Currency.unwrap(tokenCurrency), // quote
        //     2000e8 // 2000e8 // InitalMarket price were 1ETH = 2000 USDC
        // );
    }

    function test_console() public {
        console2.log("Hello there");
    }
}
