// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";

import "./TPumpHerculesV3AlgebraHandler/algebra/libraries/TickMath.sol";
import "./TPumpHerculesV3AlgebraHandler/algebra/libraries/OracleLibrary.sol";

interface IOracle {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

interface ITPump {
    function deposits(bytes32 depositID) external pure returns (uint256);

    function depositIDtoDepositor(bytes32 depositID) external pure returns (address);

    function isUSDC(address token) external pure returns (bool);

    function decimals() external pure returns (uint256);
}

interface IAlgebraPositionManager {
    function positions(uint256 positionID)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );

    function transferFrom(address from, address to, uint256 positionID) external;
    function ownerOf(uint256 positionID) external view returns (address owner);
}

interface IAlgebraPool {
    function globalState()
        external
        view
        returns (
            uint160 price,
            int24 tick,
            uint16 feeZto,
            uint16 feeOtz,
            uint16 timepointIndex,
            uint8 communityFeeToken0,
            uint8 communityFeeToken1,
            bool unlocked
        );

    function positions(bytes32 key)
        external
        view
        returns (
            uint128 liquidityAmount,
            uint32 lastLiquidityAddTimestamp,
            uint256 innerFeeGrowth0Token,
            uint256 innerFeeGrowth1Token,
            uint128 fees0,
            uint128 fees1
        );

    function token0() external view returns (address);
    function token1() external view returns (address);
}

/**
 * @dev TPumpHerculesV3AlgebraHandler.
 * Contract to handle any liquidity source compatible with Algebra DEX [V3] positions.
 *
 * NOTE Because of the _receipts system, each instance should only be used to handle one liquiditySource -e.g. one liquidity pool-
 */

contract TPumpHerculesV3AlgebraHandler is Context {
    using EnumerableSet for EnumerableSet.UintSet;
    using Math for uint256;

    address immutable WETH_ADDRESS;
    address immutable XAI_ADDRESS;
    // Uniswap V3 XAI-WETH pool
    address immutable XAI_ORACLE;

    IAlgebraPositionManager immutable ALGEBRA_POSITION_MANAGER;
    IAlgebraPool immutable ALGEBRA_POOL;

    ITPump immutable TChoke;
    address immutable oracle;

    // Mapping from holder address to their (enumerable) set of owned tokens
    mapping(address => EnumerableSet.UintSet) private _receipts;
    mapping(uint256 => address) public tokenIdToDepositor;

    error TChokeInvalidDeposit(bytes32 depositID);
    error TChokeInvalidPositionTransfer();
    error TChokeInvalidSender();
    error TChokeInvalidLiquidityPool();
    error TChokeHandlerFailedOracle();
    error TChokeHandlerNotLiquidatable();

    /**
     * @dev Main functions `handleDeposit`, `handleWithdraw` and `liquidate` must only be callable from TChoke itself.
     */
    modifier onlyTChoke() {
        if (_msgSender() != address(TChoke)) revert TChokeInvalidSender();
        _;
    }

    constructor(
        address _tChokeAddress,
        address _oracle,
        address _weth,
        address _xai,
        address _xaiOracle,
        address _algebraPositionManager,
        address _algebraLiquidityPool
    ) {
        require(_tChokeAddress != address(0), "Invalid TChoke");
        require(_oracle != address(0), "Invalid oracle");
        require(_weth != address(0), "Invalid WETH address");
        require(_xai != address(0), "Invalid XAI address");
        require(_algebraPositionManager != address(0), "Invalid AlgebraPositionManager address");
        require(_algebraLiquidityPool != address(0), "Invalid AlgebraLiquidityPool");
        require(_xaiOracle != address(0), "Invalid XAI oracle");

        WETH_ADDRESS = _weth;
        XAI_ADDRESS = _xai;
        XAI_ORACLE = _xaiOracle;
        ALGEBRA_POSITION_MANAGER = IAlgebraPositionManager(_algebraPositionManager);
        ALGEBRA_POOL = IAlgebraPool(_algebraLiquidityPool);
        TChoke = ITPump(_tChokeAddress);
        oracle = _oracle;
    }

    /**
     * @dev Proxy to do the actual `deposit` of the liquidity on behalf of tChoke. Only callable by `TChoke` itself.
     *
     * @param liquiditySource Must have been listed as a valid liquiditySource in TChoke. For this specific handler, `liquiditySource` is expected to comply with Algebra V3 NFT positions.
     * @param from Actual caller of the function forwarded to this contract to assign receipts and balances
     * @param positionID The `tokenID` of the `liquiditySource` -Algebra V3 NFT positions.-
     *
     * @return depositID {bytes32} Identifier of the deposit
     * @return tChokeAmount {uint256} Representation of the USD value of the underlying with 18 decimals.
     *
     * NOTE: Depending on the actual liquidity conditions, an external oracle may be used to validate a certain threshold when calculating `tChokeAmount` from the actual USD underlying value.
     */

    function handleDeposit(address liquiditySource, address from, uint256 positionID)
        external
        onlyTChoke
        returns (bytes32, uint256)
    {
        _validAlgebraPool(liquiditySource);

        bytes32 depositID = _calculateDepositID(liquiditySource, from, positionID);

        if (
            tokenIdToDepositor[positionID] != address(0) || TChoke.depositIDtoDepositor(depositID) != address(0)
                || TChoke.deposits(depositID) != 0
        ) revert TChokeInvalidDeposit(depositID);

        ALGEBRA_POSITION_MANAGER.transferFrom(from, address(this), positionID);

        _receipts[from].add(positionID);
        tokenIdToDepositor[positionID] = from;

        if (ALGEBRA_POSITION_MANAGER.ownerOf(positionID) != address(this)) revert TChokeInvalidPositionTransfer();

        (uint256 usdProvided) = _calculateUSDProvided(liquiditySource, positionID);
        if (usdProvided == 0) revert TChokeInvalidDeposit(depositID);

        return (depositID, usdProvided);
    }

    /**
     * @dev Proxy to do the actual `withdraw` of the liquidity on behalf of tChoke. Only callable by `TChoke` itself.
     *
     * @param liquiditySource Must have been listed as a valid liquiditySource in TChoke. For this specific handler, `liquiditySource` is expected to comply with Algebra V3 NFT positions.
     * @param to Actual caller of the function forwarded to this contract to assign receipts and balances
     * @param positionID The `tokenID` of the `liquiditySource` -Algebra V3 NFT positions.-
     *
     * @return depositID {bytes32} Identifier of the deposit which suffice getting the actual debt of the deposit. Debt is not recalculated.
     *
     */

    function handleWithdraw(address liquiditySource, address to, uint256 positionID)
        external
        onlyTChoke
        returns (bytes32)
    {
        _validAlgebraPool(liquiditySource);

        bytes32 depositID = _calculateDepositID(liquiditySource, to, positionID);

        if (
            TChoke.deposits(depositID) == 0 || tokenIdToDepositor[positionID] != to
                || TChoke.depositIDtoDepositor(depositID) != to
        ) revert TChokeInvalidDeposit(depositID);

        ALGEBRA_POSITION_MANAGER.transferFrom(address(this), to, positionID);

        _receipts[to].remove(positionID);
        tokenIdToDepositor[positionID] = address(0);

        if (ALGEBRA_POSITION_MANAGER.ownerOf(positionID) != to) {
            revert TChokeInvalidPositionTransfer();
        }

        return (depositID);
    }

    /**
     * @dev Proxy to liquidate a position. Only callable by `TChoke` itself. Must pass `_isLiquidatable` conditions that consider full position value before liquidating.
     *
     * @param source Must have been listed as a valid liquiditySource in TChoke. For this specific handler, `liquiditySource` is expected to comply with Algebra V3 NFT positions.
     * @param positionID The `tokenID` of the `liquiditySource` Algebra NFT position.
     * @param owner Owner of the position to be liquidated
     * @param liquidator Actual caller of the function forwarded to this contract to transfer the position
     *
     * @return liquidatable {bool} Whether the position should be liquidated
     * @return depositID {bytes32} Identifier of the deposit which suffice getting the actual debt of the deposit.
     * @return debt {uint256} Debt that is needed to be repaid in order for the position to be liquidated.
     *
     */
    function liquidate(address source, uint256 positionID, address owner, address liquidator)
        external
        onlyTChoke
        returns (bool, bytes32, uint256)
    {
        (bool shouldLiquidate, bytes32 depositID, uint256 debt) = _isLiquidatable(source, positionID, owner);
        if (!shouldLiquidate || depositID == bytes32(0) || debt == 0) revert TChokeHandlerNotLiquidatable();

        ALGEBRA_POSITION_MANAGER.transferFrom(address(this), liquidator, positionID);

        _receipts[owner].remove(positionID);
        tokenIdToDepositor[positionID] = address(0);

        if (ALGEBRA_POSITION_MANAGER.ownerOf(positionID) != liquidator) {
            revert TChokeInvalidPositionTransfer();
        }

        return (true, depositID, debt);
    }

    function receiptsBalance(address _owner) external view returns (uint256) {
        require(_owner != address(0), "TChoke: balance query for the zero address");
        return _receipts[_owner].length();
    }

    function receiptOfOwnerByIndex(address _owner, uint256 _index) external view returns (uint256) {
        require(_owner != address(0), "TChoke: balance query for the zero address");
        return _receipts[_owner].at(_index);
    }

    function getFullPositionValue(address liquiditySource, uint256 positionID)
        external
        view
        returns (uint256, uint256)
    {
        (int24 tickLower, int24 tickUpper, uint128 liquidity) = _getPosition(positionID, liquiditySource);

        (uint256 _xaiAmount, uint256 _wethAmount) = _amountsForLiquidity(tickLower, tickUpper, liquidity);

        (, int256 oraclePrice,,,) = IOracle(oracle).latestRoundData();
        if (oraclePrice <= 0) revert TChokeHandlerFailedOracle();

        uint256 _wethUSDProvided = _weiToUSD(_wethAmount, oraclePrice);
        uint256 _xaiUSDProvided = _calculateUSDProvidedByXAI(_xaiAmount, oraclePrice);

        return (_wethUSDProvided, _xaiUSDProvided);
    }

    function getDepositInformation(address liquiditySource, uint256 positionID)
        external
        view
        returns (uint256, uint256)
    {
        (uint256 usdProvided) = _calculateUSDProvided(liquiditySource, positionID);

        return (positionID, usdProvided);
    }

    function getDepositInformation(address liquiditySource, address depositor, uint256 positionID)
        public
        view
        returns (uint256, uint256, uint256)
    {
        (uint256 usdProvided) = _calculateUSDProvided(liquiditySource, positionID);

        bytes32 depositID = _calculateDepositID(liquiditySource, depositor, positionID);

        return (positionID, usdProvided, TChoke.deposits(depositID));
    }

    function isLiquidatable(address source, uint256 positionID, address owner)
        external
        view
        returns (bool, bytes32, uint256)
    {
        return _isLiquidatable(source, positionID, owner);
    }

    function _calculateUSDProvided(address source, uint256 positionID) private view returns (uint256) {
        _validAlgebraPool(source);

        (,, address token0, address token1, int24 tickLower, int24 tickUpper, uint128 liquidity,,,,) =
            ALGEBRA_POSITION_MANAGER.positions(positionID);

        if (token0 != XAI_ADDRESS || token1 != WETH_ADDRESS) {
            revert TChokeInvalidLiquidityPool();
        }

        (, uint256 _wethAmount) = _amountsForLiquidity(tickLower, tickUpper, liquidity);

        (, int256 oraclePrice,,,) = IOracle(oracle).latestRoundData();
        if (oraclePrice <= 0) revert TChokeHandlerFailedOracle();

        uint256 usdProvided = _weiToUSD(_wethAmount, oraclePrice);
        return ((usdProvided * 500) / 1000);
    }

    /**
     * @dev Calculates a unique {bytes32} keccak256 encoding:
     *  - The address of this smart contract (representing each instance of TPumpHerculesV3Handler)
     *  - The actual liquidity source represented by the Algebra Position NFT
     *  - The address owner of the position, which will have to repay for the debt in order to withdraw the spNFT.
     *  - The position -token- ID. This, along the liquidity source address, ensures uniqueness.
     *
     * @return depositID {bytes32}
     */
    function _calculateDepositID(address liquiditySource, address owner, uint256 positionID)
        private
        view
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(address(this), liquiditySource, owner, positionID));
    }

    /**
     * @dev Using functions from Camelot Hypervisor deployed in Arbitrum at 0x80569177c9B49a15bFaF1C73c83E67AAc791b1be
     */

    /// @notice Get the amounts of the given numbers of liquidity tokens
    /// @param tickLower The lower tick of the position
    /// @param tickUpper The upper tick of the position
    /// @param liquidity The amount of liquidity tokens
    /// @return Amount of token0 and token1
    function _amountsForLiquidity(int24 tickLower, int24 tickUpper, uint128 liquidity)
        internal
        view
        returns (uint256, uint256)
    {
        (uint160 sqrtRatioX96,,,,,,,) = ALGEBRA_POOL.globalState();
        return LiquidityAmounts.getAmountsForLiquidity(
            sqrtRatioX96, TickMath.getSqrtRatioAtTick(tickLower), TickMath.getSqrtRatioAtTick(tickUpper), liquidity
        );
    }

    /**
     * @dev Validate conditions to liquidate a position by any liquidator
     *  - Retrieves the position and deduces the amounts using tickLower, tickUpper and liquidity amount
     *  - Fetch ETH price from ChainLink oracle
     *  - Calculates the actual `debtThreshold` as a fixed percentage on top of the actual `debt`
     *  - If the amount of ETH in the position is not enough to cover `debtThreshold`, is uses the amount of XAI available to quote the ETH equivalent using as oracle a Uniswap V3 liquidity pool
     *  - If the sum of the USD equivalent in ETH AND XAI is not enough to cover for `debtThreshold`, the position should be liquidated and returns (true, `positionID` and `_debt`).
     *
     * @return depositID {bytes32}
     */
    function _isLiquidatable(address source, uint256 positionID, address owner)
        internal
        view
        returns (bool, bytes32, uint256)
    {
        (int24 tickLower, int24 tickUpper, uint128 liquidity) = _getPosition(positionID, source);

        (uint256 _xaiAmount, uint256 _wethAmount) = _amountsForLiquidity(tickLower, tickUpper, liquidity);

        (, int256 oraclePrice,,,) = IOracle(oracle).latestRoundData();
        if (oraclePrice <= 0) revert TChokeHandlerFailedOracle();

        uint256 _wethUSDProvided = _weiToUSD(_wethAmount, oraclePrice);

        bytes32 depositID = _calculateDepositID(source, owner, positionID);
        uint256 _debt = TChoke.deposits(depositID);
        if (_debt == 0) revert TChokeInvalidDeposit(depositID);

        uint256 _debtThreshold = (_debt * 11000 / 10000);

        if (_debtThreshold > _wethUSDProvided) {
            uint256 _xaiUSDProvided = _calculateUSDProvidedByXAI(_xaiAmount, oraclePrice);
            if (_debtThreshold > _xaiUSDProvided + _wethUSDProvided) {
                return (true, depositID, _debt);
            }
        }
        return (false, depositID, _debt);
    }

    function _calculateUSDProvidedByXAI(uint256 _xaiAmount, int256 oraclePrice) internal view returns (uint256) {
        (int24 currentTick,) = OracleLibrary.consult(XAI_ORACLE, 120);

        uint256 _wethEquivalent =
            OracleLibrary.getQuoteAtTick(currentTick, uint128(_xaiAmount), XAI_ADDRESS, WETH_ADDRESS);

        return _weiToUSD(_wethEquivalent, oraclePrice);
    }

    function _weiToUSD(uint256 _weiAmount, int256 oraclePrice) internal pure returns (uint256) {
        // Ensures that result is expressed in 18 decimals by dividing by oracleDecimals [8]
        return ((uint256(oraclePrice) * _weiAmount) / (10 ** 8));
    }

    function _getPosition(uint256 positionID, address source) internal view returns (int24, int24, uint128) {
        (,, address token0, address token1, int24 tickLower, int24 tickUpper, uint128 liquidity,,,,) =
            ALGEBRA_POSITION_MANAGER.positions(positionID);
        _validPool(source, token0, token1);

        return (tickLower, tickUpper, liquidity);
    }

    function _validAlgebraPool(address pool) internal view {
        if (pool != address(ALGEBRA_POOL)) revert TChokeInvalidLiquidityPool();
    }

    function _validPool(address pool, address token0, address token1) internal view {
        if (pool != address(ALGEBRA_POOL) || token0 != XAI_ADDRESS || token1 != WETH_ADDRESS) {
            revert TChokeInvalidLiquidityPool();
        }
    }
}
