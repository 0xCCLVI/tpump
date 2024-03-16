// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

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

interface IHerculesPair {
    function token0() external pure returns (address);

    function token1() external pure returns (address);

    function totalSupply() external pure returns (uint256);

    function getReserves()
        external
        view
        returns (uint112 _reserve0, uint112 _reserve1, uint16 _token0FeePercent, uint16 _token1FeePercent);
}

interface ILiquiditySource {
    function transferFrom(address from, address to, uint256 tokenId) external;

    function ownerOf(uint256 tokenId) external view returns (address);

    function getPoolInfo()
        external
        view
        returns (
            address lpToken,
            address grailToken,
            address xGrailToken,
            uint256 lastRewardTime,
            uint256 accRewardsPerShare,
            uint256 lpSupply,
            uint256 lpSupplyWithMultiplier,
            uint256 allocPoint
        );

    function getStakingPosition(uint256 tokenId)
        external
        view
        returns (
            uint256 amount,
            uint256 amountWithMultiplier,
            uint256 startLockTime,
            uint256 lockDuration,
            uint256 lockMultiplier,
            uint256 rewardDebt,
            uint256 boostPoints,
            uint256 totalMultiplier
        );
}

/**
 * @dev TPumpHerculesV2Handler.
 * Contract to handle any liquidity source compatible with spNFT infrastructure of Camelot V2 DEX.
 *
 * NOTE Because of the _receipts system, each instance should only be used to handle one liquiditySource -e.g. one liquidity pool-
 */

contract TPumpHerculesV2Handler is Context {
    using EnumerableSet for EnumerableSet.UintSet;

    ITPump immutable TChoke;
    address immutable oracle;

    uint8 constant USDC_DECIMALS = 6;

    // Mapping from holder address to their (enumerable) set of owned tokens
    mapping(address => EnumerableSet.UintSet) private _receipts;
    mapping(uint256 => address) public tokenIdToDepositor;

    error TChokeInvalidDeposit(bytes32 depositID);
    error TChokeInvalidPositionTransfer();
    error TChokeInvalidSender();
    error TChokeInvalidLiquidityPool();
    error TChokeHandlerFailedOracle();

    /**
     * @dev Both main functions `handleDeposit` and `handleWithdraw` should only be callable from TChoke itself.
     */
    modifier onlyTChoke() {
        if (_msgSender() != address(TChoke)) revert TChokeInvalidSender();
        _;
    }

    constructor(address _tChokeAddress, address _oracle) {
        require(_tChokeAddress != address(0), "Invalid TChoke");
        require(_oracle != address(0), "Invalid oracle");

        TChoke = ITPump(_tChokeAddress);
        oracle = _oracle;
    }

    /**
     * @dev Proxy to do the actual `deposit` of the liquidity on behalf of tChoke. Only callable by `TChoke` itself.
     *
     * @param liquiditySource Must have been listed as a valid liquiditySource in TChoke. For this specific handler, `liquiditySource` is expected to comply with spNFT interface.
     * @param from Actual caller of the function forwarded to this contract to assign receipts and balances
     * @param positionID The `tokenID` of the `liquiditySource` -spNFT-
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
        bytes32 depositID = _calculateDepositID(liquiditySource, from, positionID);

        if (
            tokenIdToDepositor[positionID] != address(0) || TChoke.depositIDtoDepositor(depositID) != address(0)
                || TChoke.deposits(depositID) != 0
        ) revert TChokeInvalidDeposit(depositID);

        ILiquiditySource source = ILiquiditySource(liquiditySource);

        source.transferFrom(from, address(this), positionID);

        _receipts[from].add(positionID);
        tokenIdToDepositor[positionID] = from;

        if (source.ownerOf(positionID) != address(this)) {
            revert TChokeInvalidPositionTransfer();
        }

        (uint256 usdProvided,,) = _calculateUSDProvided(source, positionID);
        if (usdProvided == 0) revert TChokeInvalidDeposit(depositID);

        return (depositID, usdProvided);
    }

    /**
     * @dev Proxy to do the actual `withdraw` of the liquidity on behalf of tChoke. Only callable by `TChoke` itself.
     *
     * @param liquiditySource Must have been listed as a valid liquiditySource in TChoke. For this specific handler, `liquiditySource` is expected to comply with spNFT interface.
     * @param to Actual caller of the function forwarded to this contract to assign receipts and balances
     * @param positionID The `tokenID` of the `liquiditySource` -spNFT-
     *
     * @return depositID {bytes32} Identifier of the deposit which suffice getting the actual debt of the deposit. Debt is not recalculated.
     *
     */

    function handleWithdraw(address liquiditySource, address to, uint256 positionID)
        external
        onlyTChoke
        returns (bytes32)
    {
        bytes32 depositID = _calculateDepositID(liquiditySource, to, positionID);

        if (
            TChoke.deposits(depositID) == 0 || tokenIdToDepositor[positionID] != to
                || TChoke.depositIDtoDepositor(depositID) != to
        ) revert TChokeInvalidDeposit(depositID);

        ILiquiditySource source = ILiquiditySource(liquiditySource);

        source.transferFrom(address(this), to, positionID);

        _receipts[to].remove(positionID);
        tokenIdToDepositor[positionID] = address(0);

        if (source.ownerOf(positionID) != to) {
            revert TChokeInvalidPositionTransfer();
        }

        return (depositID);
    }

    function receiptsBalance(address _owner) external view returns (uint256) {
        require(_owner != address(0), "TChoke: balance query for the zero address");
        return _receipts[_owner].length();
    }

    function receiptOfOwnerByIndex(address _owner, uint256 _index) external view returns (uint256) {
        require(_owner != address(0), "TChoke: balance query for the zero address");
        return _receipts[_owner].at(_index);
    }

    function getDepositInformation(address liquiditySource, uint256 positionID)
        external
        view
        returns (uint256, uint256, uint256, uint256)
    {
        ILiquiditySource source = ILiquiditySource(liquiditySource);

        (uint256 usdProvided, uint256 lpAmount, uint256 totalSupply) = _calculateUSDProvided(source, positionID);

        return (positionID, usdProvided, lpAmount, totalSupply);
    }

    function getDepositInformation(address liquiditySource, address depositor, uint256 positionID)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256)
    {
        ILiquiditySource source = ILiquiditySource(liquiditySource);

        (uint256 usdProvided, uint256 lpAmount, uint256 totalSupply) = _calculateUSDProvided(source, positionID);

        bytes32 depositID = _calculateDepositID(liquiditySource, depositor, positionID);

        return (positionID, usdProvided, lpAmount, totalSupply, TChoke.deposits(depositID));
    }

    function _calculateUSDProvided(ILiquiditySource source, uint256 positionID)
        private
        view
        returns (uint256, uint256, uint256)
    {
        (address lpTokenAddress,,,,,,,) = source.getPoolInfo();
        (uint256 lpAmount,,,,,,,) = source.getStakingPosition(positionID);

        IHerculesPair camelotPair = IHerculesPair(lpTokenAddress);
        (uint112 _reserve0, uint112 _reserve1,,) = camelotPair.getReserves();

        uint256 totalSupply = camelotPair.totalSupply();

        uint112 usdcReserve;
        uint256 usdProvided;

        (, int256 oraclePrice,,,) = IOracle(oracle).latestRoundData();
        if (oraclePrice == 0) revert TChokeHandlerFailedOracle();

        if (TChoke.isUSDC(camelotPair.token0())) {
            usdcReserve = _reserve0;
            _validateOraclePrice(_reserve1, usdcReserve, oraclePrice);
        } else if (TChoke.isUSDC(camelotPair.token1())) {
            usdcReserve = _reserve1;
            _validateOraclePrice(_reserve0, usdcReserve, oraclePrice);
        } else {
            revert TChokeInvalidLiquidityPool();
        }

        usdProvided = ((usdcReserve * lpAmount) / totalSupply) * (10 ** (TChoke.decimals() - USDC_DECIMALS));

        return (usdProvided, lpAmount, totalSupply);
    }

    function _validateOraclePrice(uint256 assetReserves, uint256 usdcReserves, int256 latestAnswer) private pure {
        // Assuming any asset with 18 decimals and usdcReserves always with 6 decimals
        // Ratio will result in the usdcPrice with 8 decimals
        int256 ratio = int256((usdcReserves * (10 ** 20)) / assetReserves);
        // 2% threshold
        int256 threshold = (latestAnswer * 2) / 100;
        if (ratio > latestAnswer) {
            if (ratio - latestAnswer > threshold) {
                revert TChokeHandlerFailedOracle();
            }
        } else {
            if (latestAnswer - ratio > threshold) {
                revert TChokeHandlerFailedOracle();
            }
        }
    }

    /**
     * @dev Calculates a unique {bytes32} keccak256 encoding:
     *  - The address of this smart contract (representing each instance of TPumpHerculesV2Handler)
     *  - The actual liquidity source represented by the spNFT wrapper of any valid Camelot V2 liquidity pool
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
}
