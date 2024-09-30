// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
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
// Contract to create a orderbook factory
import {OrderbookFactory} from "@standardweb3/exchange/orderbooks/OrderbookFactory.sol";
import {Helpers} from "./utils/Helpers.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {EasyPosm} from "./utils/EasyPosm.sol";
import {Fixtures} from "./utils/Fixtures.sol";

/**
        PlacerOrder in the beforeSwap function, mintERC1155 receipt that represents the placedOrder.
        in afterSwapOrder we matched the order if there is any 

    */
/**
    Amount of ETH specified to swap throught swap = amountSpecified: -1000000000000000 [-1e15]
    Amount of ETH specified throught the hookData is = amountSpecified: 100000 [1e5]
    1- trader deposited throught 'swap' to the poolManager "-1000000000000000 [-1e15]"(0.001) ether 
    2- trader specified in the hook data the amount that they which to trade on the orderbook using limitSell => 100000 [1e5]
    the amount is then taken from the pool ETH/TOKEN pool in the poolManager and transfered to the Hook
    3- The Hook place the order on behalf of the trader in the orderBook
    4- Order placed the swap with delta.amount0() = -999999999900000 [-9.999e14], delta.amount1() = amount1: 996006980940401 [9.96e14]
    NOTE: 
    - The amount is taken from the inital deposit to the PoolManager "-1000000000000000 [-1e15]"(0.001) ether
    - The trader in the OrderHook data only specified the amount they want to take from their inital deposit without specifying 
    - When Swap is deducted using this hybrid sytem: The amount specified throught hooks data is deducted from from the totalAmount 
    deposited by the user. deposited to the orderbook awaiting for match. once the order swap is conducted throuht swapRouter
    is conducted using the remaning amount in the pool in our case:
    // Order placed the swap with delta.amount0() = -999999999900000 [-9.999e14](minus orderbook amount), delta.amount1() = amount1: 996006980940401 [9.96e14]
    decimals number: example 100_000 whcih appears in the log with 100000(1e5);
    TODO: Investigate more how the matching engine handle decimals in this case or its just it just with ETH
    but still try to do it with ERC20 tokens and don't specify decimals vs Specify decimals
    TODO: Who should I set as receiver in the OrderHook data => From the flow of funds I think it's poolManager address
    TODO: try to match the placed order using afterswap hook.
    


 */
contract OrderBookHookV4Test is Test, Helpers, Fixtures {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    OrderBookHookV4 hook;
    address UniToken;
    IERC20Mock UNITOKEN;

    address dydxToken;
    IERC20Mock DYDXTOKEN;

    Currency tokenCureency1;
    Currency tokenCurrency0;

    address public trader1;
    address public trader2;
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
        vm.label(UniToken, "UNITOKEN");

        vm.label(address(address(this)), "Test Contract");

        // Deploy the Wrapped ETH
        WETH weth = new WETH();
        vm.label(address(weth), "WETH");

        // 1- Deploy the matching Engine and connect with the orderbook factory
        //----------------------------------------------------------------------
        // NOTE: address(this) has a admin role
        // deploy Orderbookfactory contract.
        OrderbookFactory orderBookFactory = new OrderbookFactory();

        // deploy matchineEngineFactory contract
        MatchingEngine matchingEngine = new MatchingEngine();

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
        Currency ethCurrency = Currency.wrap(address(0));

        UNITOKEN.mint(address(this), 1_000 ether);
        UNITOKEN.mint(trader1, 1_0000 ether);
        UNITOKEN.mint(trader2, 1_0000 ether);

        //****************************************************************/
        dydxToken = address(new MockERC20("DYDX TOKEN", "DYDX", 8));
        DYDXTOKEN = IERC20Mock(dydxToken);

        // Wrap DYDX token to currency type
        tokenCurrency0 = Currency.wrap(address(dydxToken));

        DYDXTOKEN.mint(address(this), 1_000 ether);
        DYDXTOKEN.mint(trader1, 1_000 ether);
        DYDXTOKEN.mint(trader2, 1_000 ether);

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
        hook = OrderBookHookV4(payable(flags)); // @audit-info check payable if it revert
        vm.label(address(hook), "Hook Contract");

        approveCurrencies(UniToken, address(this), addressesToApprove);
        approveCurrencies(dydxToken, address(this), addressesToApprove);

        approveCurrencies(UniToken, trader1, addressesToApprove);
        approveCurrencies(dydxToken, trader1, addressesToApprove);

        approveCurrencies(UniToken, trader2, addressesToApprove);
        approveCurrencies(dydxToken, trader2, addressesToApprove);

        // Approve Max amount of UNITOKEN to be spend by swap router and modifyliquidity router
        // address(this) approval
        // UNITOKEN.approve(address(swapRouter), type(uint256).max);
        // UNITOKEN.approve(address(modifyLiquidityRouter), type(uint256).max);
        // UNITOKEN.approve(address(matchingEngine), type(uint256).max);

        // vm.startPrank(trader1);
        // UNITOKEN.approve(address(swapRouter), type(uint256).max);
        // UNITOKEN.approve(address(modifyLiquidityRouter), type(uint256).max);
        // UNITOKEN.approve(address(matchingEngine), type(uint256).max);
        // vm.stopPrank();
        // Initilize a pool with Unitoken as the base and dydxToken as the quote UNI/DYDX
        (key, ) = initPool(
            ethCurrency,
            tokenCureency1,
            hook,
            3000,
            SQRT_PRICE_1_1,
            ZERO_BYTES
        );

        // add the above pair UNI/DYDX in the matching engine contract
        matchingEngine.addPair(
            address(weth), // base DYDX
            Currency.unwrap(tokenCureency1), // quote UNI
            2000e8 // 2000e8 // InitalMarket price were 1 UNI = 1 DYDX
        );
    }

    // TODO: use ERC20s Tokens case. Include the case of swapping ERC20 for ERC20.
    // Use simple use case where we want to swap 2 token for 2 token
    function test_addLiquidityAndSwap() public {
        // // // Set no referrer in the hook data
        // bytes memory hookData = hook.getHookData(
        //     10e8, // => limitPrice in the order book were (1 UNI per DYDX)
        //     5e18, // => The amount of base asset to be used for the limit sell order
        //     address(trader1), // set the address of the hook as the recipient addeess // It can be the swaprouter, PoolManager, contractHook
        //     true,
        //     2 // @param n The maximum number of orders to match in the orderbook
        // );

        // bytes memory hookData = new bytes(0);

        uint256 traderBalTokenBefore = UNITOKEN.balanceOf(address(trader1));
        uint256 hookBalTokenBefore = UNITOKEN.balanceOf(address(hook));
        uint256 testContractBalTokenBefore = UNITOKEN.balanceOf(
            address(address(this))
        );

        console2.log(
            "Trader Balance in Uni before Swap ",
            traderBalTokenBefore
        );
        console2.log(
            "Hook contract Balance in Uni before Swap ",
            hookBalTokenBefore
        );
        console2.log(
            "TestContract Balance in Uni before Swap ",
            testContractBalTokenBefore
        );

        // NOTE: Provide liquidity with 0.003 ether and the rest of 1 rest in UNITOKEN
        // TODO: ==> do the same for ERC20 tokens (getAmountsForLiquidity) <==
        // Note: Address (this provide liquidity for it own funds)
        // getAmountsForLiquidity
        // How we landed on 0.003 ether here is based on computing value of x and y given
        // total value of delta L (liquidity delta) = 1 ether
        // This is done by computing x and y from the equation shown in Ticks and Q64.96 Numbers lesson
        // View the full code for this lesson on GitHub which has additional comments
        // showing the exact computation and a Python script to do that calculation for you
        modifyLiquidityRouter.modifyLiquidity{value: 0.003 ether}(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 1 ether, // we provide 10 as liquidity to the pool(key)
                salt: 0
            }),
            new bytes(0)
        );

        // Hook Orderbook data for trader1
        bytes memory trader1HookData = hook.getHookData(
            // TODO: Change the price to the current price if it's revert
            2000e8, // => limitPrice in the order book were (1 UNI per DYDX)
            100000, // => The amount of base asset to be used for the limit sell order
            address(trader1), // set the address of the hook as the recipient addeess // It can be the swaprouter, PoolManager, contractHook
            true,
            2 // @param n The maximum number of orders to match in the orderbook
        );

        // // Now we swap
        // // We will swap 0.001 ether for tokens
        // // We should get 20% of 0.001 * 10**18 points
        // // = 2 * 10**14

        // CASE 1: PLACED ORDER
        // Trader1 place an order in the orderbook throught the hookData to sell DYDX and received UNI (DYDX/UNI)
        // with 5 DYDX throught AMM & 5 DYDX throught the orderbook => total = 10 DYDX for UNISWAP token
        // vm.startPrank(trader1);
        // swapRouter.swap(
        //     key,
        //     IPoolManager.SwapParams({
        //         zeroForOne: true,
        //         amountSpecified: -5e18, // negative => expect the exact amount of input tokens
        //         sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        //     }),
        //     PoolSwapTest.TestSettings({
        //         takeClaims: false, // false = ERC20 : true: ERC6909s
        //         settleUsingBurn: false
        //     }),
        //     new bytes(0)
        // );
        // vm.stopPrank();

        // CASE 1: PLACED ORDER
        // Trader1 place an order in the orderbook throught the hookData to sell DYDX and received UNI (DYDX/UNI)
        // with 5 DYDX throught AMM & 5 DYDX throught the orderbook => total = 10 DYDX for UNISWAP token
        vm.startPrank(trader1);
        swapRouter.swap{value: 0.001 ether}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -0.001 ether, // negative => expect the exact amount of input tokens
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: true, // false = ERC20 : true: ERC6909s
                settleUsingBurn: false
            }),
            trader1HookData
        );
        vm.stopPrank();

        // // 0x5991A2dF15A8F6A256D3Ec51E99254Cd3fb576A9
        // Result for 1782000000 UNI the Received 198000000 ether
        bytes memory trader2HookData = hook.getHookData(
            // TODO: Change the price to the current price if it's revert
            2000e8, // => limitPrice in the order book were (1 UNI per DYDX)
            1782000000, // Amount of UNI to swap (178,200,000 * 10^8) for 90% of ETH in the orderbook // @audit-info this might be the reason for revert as it include decimals
            address(trader2), // set the address of the hook as the recipient addeess // It can be the swaprouter, PoolManager, contractHook
            true, // @audit-info set this to true.
            2 // @param n The maximum number of orders to match in the orderbook
        );

        // Trader2 matched the orderSwap Tokens for ETH
        vm.startPrank(trader2);
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: false,
                // // I need to figout out how of token will fillhout the trader1 place order then put inside the orderhookData
                amountSpecified: -4782000000, // @audit check if "ether" is needed
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: true, // false = ERC20 : true: ERC6909s
                settleUsingBurn: false
            }),
            trader2HookData
        );

        // vm.stopPrank();

        // // Hook Orderbook data for trader2 to matche trader1 palced order with marketBuy
        // bytes memory trader2HookData = hook.getHookData(
        //     10e8, // => limitPrice in the order book were (1 UNI per DYDX)
        //     5e18, // => The amount of quote asset to be used for the market buy order
        //     address(trader2), // set the address of the hook as the recipient addeess // It can be the swaprouter, PoolManager, contractHook
        //     true,
        //     2 // @param n The maximum number of orders to match in the orderbook
        // );

        // // CASE 2: MATCHED ORDER
        // // Trader2 place an order in the orderbook throught the hookData to buy DYDX and sell UNI (DYDX/UNI)
        // // with 5 UNI throught AMM & 5 UNI throught the orderbook => total = 10 UNI for 10 DYDXTOKEN token
        // vm.startPrank(trader2);
        // swapRouter.swap(
        //     key,
        //     IPoolManager.SwapParams({
        //         zeroForOne: false,
        //         amountSpecified: -5e18, // negative => expect the exact amount of input tokens
        //         sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        //     }),
        //     PoolSwapTest.TestSettings({
        //         takeClaims: true, // false = ERC20 : true: ERC6909s
        //         settleUsingBurn: false
        //     }),
        //     trader2HookData
        // );
        // vm.stopPrank();

        // uint256 traderBalTokenAfter = UNITOKEN.balanceOf(address(trader1));
        // uint256 hookBalTokenAfter = UNITOKEN.balanceOf(address(hook));
        // uint256 testContractBalTokenAfter = UNITOKEN.balanceOf(
        //     address(address(this))
        // );

        // console2.log("Trader Balance in Uni After Swap", traderBalTokenAfter);

        // console2.log(
        //     "Hook contract Balance in Uni After Swap ",
        //     hookBalTokenAfter
        // );

        // console2.log(
        //     "TestContract Balance in Uni before Swap ",
        //     testContractBalTokenAfter
        // );

        // console.log the difference.
    }
}
