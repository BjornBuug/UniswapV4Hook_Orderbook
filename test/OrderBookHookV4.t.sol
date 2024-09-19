// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

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

contract OrderBookHookV4Test is Test, Helpers, Fixtures {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    OrderBookHookV4 hook;
    address UniToken;
    IERC20Mock UNITOKEN;
    Currency tokenCurrency;

    address public trader1;
    address public admin;
    address[] public users;

    PoolId poolId;

    uint256 tokenId;
    PositionConfig config;

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

        // Deploy ERC20 tokens
        UniToken = address(new MockERC20("UNISWAP", "UNI", 18));
        UNITOKEN = IERC20Mock(UniToken);

        // wrap the tokens to currency type
        tokenCurrency = Currency.wrap(address(UniToken));
        Currency ethCurrency = Currency.wrap(address(0));

        UNITOKEN.mint(address(this), 1_000 ether);
        UNITOKEN.mint(trader1, 1_0000 ether);

        // Deploy the hook to an address with the correct flags
        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG |
                    Hooks.AFTER_SWAP_FLAG |
                    Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
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

        // Approve Max amount of UNITOKEN to be spend by swap router and modifyliquidity router
        // address(this) approval
        UNITOKEN.approve(address(swapRouter), type(uint256).max);
        UNITOKEN.approve(address(modifyLiquidityRouter), type(uint256).max);
        UNITOKEN.approve(address(matchingEngine), type(uint256).max);

        // Traders Approval
        vm.startPrank(trader1);
        UNITOKEN.approve(address(swapRouter), type(uint256).max);
        UNITOKEN.approve(address(modifyLiquidityRouter), type(uint256).max);
        UNITOKEN.approve(address(matchingEngine), type(uint256).max);
        vm.stopPrank();

        // Initilize a pool
        (key, ) = initPool(
            ethCurrency,
            tokenCurrency,
            hook,
            3000,
            SQRT_PRICE_1_1,
            ZERO_BYTES
        );

        // add the above pair in the matching engine contract
        matchingEngine.addPair(
            address(weth), // base
            Currency.unwrap(tokenCurrency), // quote
            2000e8 // 2000e8 // InitalMarket price were 1ETH = 2000 USDC
        );
    }

    // 10000000996006980940401 || 996006980940401
    // Include the case of swapping ERC20 for ERC20.
    // Use simple use case where we want to swap 2 token for 2 token
    function test_addLiquidityAndSwap() public {
        // Set no referrer in the hook data
        bytes memory hookData = hook.getHookData(
            2000e8, // => limitPrice in the order book were 1ETH = 2000 USDC
            100000,
            address(trader1), // It can be the swaprouter, PoolManager, contractHook
            true,
            2 // @param n The maximum number of orders to match in the orderbook
        );

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
                liquidityDelta: 1 ether, // we provide 1 as liquidity to the pool(key)
                salt: 0
            }),
            hookData
        );

        // Now we swap
        // We will swap 0.001 ether for tokens
        // We should get 20% of 0.001 * 10**18 points
        // = 2 * 10**14
        vm.prank(trader1);
        swapRouter.swap{value: 0.001 ether}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -0.001 ether, // Exact input for output swap
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false, // false = ERC20 : true: ERC6909s
                // what can I do with these tokens @Search
                settleUsingBurn: false
            }),
            hookData
        );

        uint256 traderBalTokenAfter = UNITOKEN.balanceOf(address(trader1));
        uint256 hookBalTokenAfter = UNITOKEN.balanceOf(address(hook));
        uint256 testContractBalTokenAfter = UNITOKEN.balanceOf(
            address(address(this))
        );

        console2.log("Trader Balance in Uni After Swap", traderBalTokenAfter);

        console2.log(
            "Hook contract Balance in Uni After Swap ",
            hookBalTokenAfter
        );

        console2.log(
            "TestContract Balance in Uni before Swap ",
            testContractBalTokenAfter
        );

        // console.log the difference.
    }
}
