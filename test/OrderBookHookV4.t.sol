// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IOrderbook} from "@standardweb3/exchange/interfaces/IOrderbook.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {OrderBookHookV4} from "../src/OrderBookHookV4.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PositionConfig} from "v4-periphery/src/libraries/PositionConfig.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC20Mock} from "../test/utils/IERC20Mock.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";
import {MatchingEngine} from "@standardweb3/exchange/MatchingEngine.sol";
import {IEngine} from "@standardweb3/exchange/interfaces/IEngine.sol";
// Contract to create a orderbook factory
import {OrderbookFactory} from "@standardweb3/exchange/orderbooks/OrderbookFactory.sol";
import {Helpers} from "./utils/Helpers.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {EasyPosm} from "./utils/EasyPosm.sol";
import {Fixtures} from "./utils/Fixtures.sol";

contract OrderBookHookV4Test is Test, Helpers, Fixtures {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    PoolKey key_1;
    PoolKey key_2;

    OrderBookHookV4 hook;
    address UniToken;
    IERC20Mock UNITOKEN;

    address dydxToken;
    IERC20Mock DYDXTOKEN;

    Currency tokenCureency1;
    Currency tokenCurrency0;

    address public trader1;
    address public orderBook1;
    address public orderBook2;
    address public trader2;
    address public orderBookFactory;
    address public matchingEngine;
    address public admin;
    address[] public users;

    PoolId poolId;

    uint256 tokenId;
    PositionConfig config;

    function setUp() public {
        users = Helpers.createUsers(4);
        trader1 = users[0];
        admin = users[1];
        trader2 = users[2];

        vm.label(trader1, "Trader1");
        vm.label(trader2, "Trader2");
        vm.label(admin, "Admin");

        vm.label(address(address(this)), "Test Contract");

        // Deploy the Wrapped ETH
        WETH weth = new WETH();
        vm.label(address(weth), "WETH");

        // 1- Deploy the matching Engine and connect with the orderbook factory
        //----------------------------------------------------------------------
        // NOTE: address(this) has a admin role
        // deploy Orderbookfactory contract.
        orderBookFactory = address(new OrderbookFactory());

        // deploy matchineEngineFactory contract
        matchingEngine = address(new MatchingEngine());

        // Intilize the OrderBook factory
        orderBookFactory.initialize(address(matchingEngine));

        // Initilize the matching Engine
        matchingEngine.initialize(
            address(orderBookFactory),
            address(admin), // could be payable
            address(weth)
        );

        // creates the pool manager, utility routers, and test tokens
        deployFreshManagerAndRouters();

        // create a fixed size array to push the address that we want to approve
        address[3] memory addressesToApprove = [
            address(swapRouter),
            address(modifyLiquidityRouter),
            address(matchingEngine)
        ];

        //****************************************************************/
        // Deploy ERC20 Uniwap tokens
        UniToken = address(new MockERC20("UNISWAP", "UNI", 18));
        UNITOKEN = IERC20Mock(UniToken);

        // wrap the tokens to currency type
        tokenCureency1 = Currency.wrap(address(UniToken));
        vm.label(Currency.unwrap(tokenCureency1), "UNITOKEN");

        Currency ethCurrency = Currency.wrap(address(0));

        UNITOKEN.mint(address(this), 10_000 ether);
        UNITOKEN.mint(trader1, 10_000 ether);
        UNITOKEN.mint(trader2, 10_000 ether);

        //****************************************************************/
        dydxToken = address(new MockERC20("DYDX TOKEN", "DYDX", 18));
        DYDXTOKEN = IERC20Mock(dydxToken);

        // Wrap DYDX token to currency type
        tokenCurrency0 = Currency.wrap(address(dydxToken));
        vm.label(Currency.unwrap(tokenCurrency0), "DYDXToken");

        DYDXTOKEN.mint(address(this), 10_000 ether);
        DYDXTOKEN.mint(trader1, 10_000 ether);
        DYDXTOKEN.mint(trader2, 10_000 ether);

        // TODO: Add Hooks.AFTER_SWAP_FLAG |
        // Hooks.BEFORE_SWAP_FLAG |
        // | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        // Deploy the hook to an address with the correct flags
        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0x4444 << 144) // Namespace the hook to avoid collisions
        );

        bytes memory constructorArgs = abi.encode(
            manager,
            address(matchingEngine),
            address(weth)
        );

        deployCodeTo(
            "OrderBookHookV4.sol:OrderBookHookV4",
            constructorArgs,
            flags
        );
        hook = OrderBookHookV4(payable(flags));
        vm.label(address(hook), "Hook Contract");

        approveCurrencies(UniToken, address(this), addressesToApprove);
        approveCurrencies(dydxToken, address(this), addressesToApprove);

        approveCurrencies(UniToken, trader1, addressesToApprove);
        approveCurrencies(dydxToken, trader1, addressesToApprove);

        approveCurrencies(UniToken, trader2, addressesToApprove);
        approveCurrencies(dydxToken, trader2, addressesToApprove);

        /************************ NATICE/ERC20 POOL **********************/
        // Initilize a pool with NATIVE as the base and UNITOKEN as the quote ETH/UNI
        (key_1, ) = initPool(
            ethCurrency,
            tokenCureency1,
            hook,
            3000,
            SQRT_PRICE_1_1,
            ZERO_BYTES
        );

        // add NATIVE/UNI pair in the matching engine contract by creating an orderbook
        orderBook1 = matchingEngine.addPair(
            address(weth), // WETH/NATIVE
            Currency.unwrap(tokenCureency1), // quote UNI
            2000e8 // 2000e8 // InitalMarket price 1ETH = 2000 UNI
        );

        /************************ ERC20/ERC20 POOL **********************/
        // Initilize a pool with Unitoken as the base and dydxToken as the quote UNI/DYDX
        (key_2, ) = initPool(
            tokenCurrency0, // DYDX
            tokenCureency1, // UNI
            hook,
            3000,
            SQRT_PRICE_1_1,
            ZERO_BYTES
        );

        // add DYDX/UNI pair in the matching engine contract by creating a Pair
        orderBook2 = matchingEngine.addPair(
            Currency.unwrap(tokenCurrency0), // base DYDX
            Currency.unwrap(tokenCureency1), // quote UNI
            100e8 // InitalMarket price were 1 UNI = 1 DYDX
        );
    }

    function test_addLiquidity_Swap_LimitOrder_NATIVE() public {
        //*** PROVIDE LIQUIDITY TO THE POOL FOR WETH/UNI PAIR ***//
        modifyLiquidityRouter.modifyLiquidity{value: 5000 ether}(
            key_1,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 10_000 ether,
                salt: 0
            }),
            new bytes(0)
        );

        // TODO: Get the balances of the pool ETH/UNI in ETH and UNI tokens after providing liquidity

        /*******************************************ORDER NUM: 1 => Limit Sell Order************************************************/

        // Trader1 balance in ETH and UNI before conducting the swap throught the orderbook and the AMM
        uint256 trader1EthBalBefSwap = address(trader1).balance;
        uint256 trader1UniBalBefSwap = UNITOKEN.balanceOf(address(trader1));

        console2.log("trader1 Eth Bal Bef Swap", trader1EthBalBefSwap);
        console2.log("trader1 Uni Bal Bef Swap", trader1UniBalBefSwap);

        // Hook Orderbook data for trader1 to place a limit order of 100,000(1e5) at a price of 2000e8
        bytes memory trader1HookData = hook.getHookData(
            2000e8, // Limit price (1 ETH = 2000 UNI)
            2 ether, // Base asset amount for the limit sell order
            address(trader1),
            true, // indicating if the order should be placed at limit price
            2 // The maximum number of orders to match in the orderbook
        );

        // @INFO
        // LIMIT ORDER 1: SELL/SWAP ETH FOR UNI
        // Trader1 places a limit order in the orderbook via hookData to sell 100,000(1e5) Native at a limit price of 2000e8 (2000 UNI per ETH).
        // Trader1 commits -0.001 ETH (1e15 wei) to swap ETH/UNI, with 100,000 UNI placed as a limit order.
        // This is passed thought HookData and executed via the Hooks contract(beforeSwap) and managed within the Orderbook contract.
        // vm.startPrank(trader1);
        swapRouter.swap{value: 4 ether}(
            key_1,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -4 ether, // negative => expect the exact amount of input tokens
                sqrtPriceLimitX96: MIN_PRICE_LIMIT //
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            trader1HookData
        );
        vm.stopPrank();

        uint256 trader1EthBalAftSwap = address(trader1).balance;
        uint256 trader1UniBalAftSwap = UNITOKEN.balanceOf(address(trader1));

        vm.assertEq(trader1UniBalBefSwap, trader1UniBalBefSwap);

        console2.log("trader1 Eth Bal Aft Swap", trader1EthBalAftSwap);
        console2.log("trader1 Uni Bal Aft Swap", trader1UniBalAftSwap);

        /*******************************************ORDER NUM: 2 => Limit Buy Order **********************************************/

        // get the required amount in UNI tokens to match 100% of the Trader1 order without fee
        uint256 requiredAmount = IOrderbook(orderBook1).getRequired(
            false, // => is bid (False) => Trader1 order is an ask not a bid
            2000e8,
            1 // => trader1 OrderID
        );

        // calculate the fee on the requirementAmount that trader2 has to pay to match 100% trader1 placedOrder
        uint256 fee = IEngine(address(matchingEngine)).feeCalculator(
            requiredAmount,
            trader2,
            true
        );

        console2.log("required Amount", fee);
        console2.log("required Amount", requiredAmount);

        // Hook Orderbook data for trader2 to place a limit buy order of 1782000000 of UNI at a price of 2000e8
        bytes memory trader2HookData = hook.getHookData(
            2000e8, // Limit price (1 ETH = 2000 UNI)
            // Amount of UNI to swap (178,200,000 * 10^8) for 90% of ETH in the orderbook
            requiredAmount + fee, // // Base asset amount for the limit buy order
            address(trader2),
            true,
            2 // The maximum number of orders to match in the orderbook
        );

        // // Trader2 matched the orderSwap Tokens for ETH
        vm.startPrank(trader2);
        swapRouter.swap(
            key_1,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -6000e18,
                sqrtPriceLimitX96: MAX_PRICE_LIMIT // To allow for maximum slippage.
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            trader2HookData
        );
    }

    function test_addLiquidity_Swap_LimitOrder_ERC20() public {
        //*** PROVIDE LIQUIDITY TO THE POOL FOR DYDX/UNI PAIR ***//
        modifyLiquidityRouter.modifyLiquidity(
            key_2,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 10_000e18,
                salt: 0
            }),
            new bytes(0)
        );

        /*******************************************ORDER NUM: 1 => Limit Sell Order************************************************/
        // Hook Orderbook data for trader1 to place a limit order of 100,000(1e5) at a price of 2000e8
        bytes memory trader1HookData = hook.getHookData(
            100e8, // Limit price (1 DYDX = 100 UNI)
            1 ether, // Base asset amount for the limit sell order
            address(trader1),
            true,
            2 // The maximum number of orders to match in the orderbook
        );

        // @INFO
        // LIMIT ORDER 1: SELL/SWAP DYDX FOR UNI
        // Trader1 places a limit order in the orderbook via hookData to sell 100,000(1e5) Native at a limit price of 2000e8 (2000 UNI per ETH).
        // Trader1 commits -0.001 ETH (1e15 wei) to swap ETH/UNI, with 100,000 UNI placed as a limit order.
        // This is passed thought HookData and executed via the Hooks contract(beforeSwap) and managed within the Orderbook contract.
        vm.startPrank(trader1);

        swapRouter.swap(
            key_2,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -10 ether, // negative => expect the exact amount of input tokens
                sqrtPriceLimitX96: MIN_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            trader1HookData
        );

        vm.stopPrank();

        // Result: Users placed A limit sell order in the Orderbook to sell [9.9e17] DYDX for UNI token at a price of 100 ether.

        /*******************************************ORDER NUM: 2 => Limit Buy Order **********************************************/
        // Hook Orderbook data for trader2 to place a limit buy order of 1782000000 of UNI at a price of 2000e8
        bytes memory trader2HookData = hook.getHookData(
            100e8, // Limit price (1 ETH = 2000 UNI)
            // Amount of UNI to swap (178,200,000 * 10^8) for 90% of ETH in the orderbook
            1 ether, // // Base asset amount for the limit buy order
            address(trader2),
            true,
            2 // The maximum number of orders to match in the orderbook
        );

        // Trader2 matched the orderSwap Tokens for ETH
        vm.startPrank(trader2);
        swapRouter.swap(
            key_2,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -2 ether,
                sqrtPriceLimitX96: MAX_PRICE_LIMIT // for testing purposes
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            trader2HookData
        );
    }
}
