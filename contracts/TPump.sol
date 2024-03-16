// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

interface ITPumpHandler {
    function handleDeposit(address liquiditySource, address from, uint256 positionID)
        external
        returns (bytes32 depositID, uint256 tChokeAmount);

    function handleWithdraw(address liquiditySource, address to, uint256 positionID)
        external
        returns (bytes32 depositID);
}

contract TPump is
    Initializable,
    ReentrancyGuardUpgradeable,
    AccessControlUpgradeable,
    ERC20Upgradeable,
    ERC20BurnableUpgradeable
{
    bytes32 public constant LIQUIDITY_MANAGER_ROLE = keccak256("LIQUIDITY_MANAGER");
    bytes32 public constant DEBT_MANAGER_ROLE = keccak256("DEBT_MANAGER");

    /**
     * @dev Both representations of Arbitrum USDC (bridged or native) are valid in terms of liquidity availability.
     */
    address public constant USDCe = 0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8;
    address public constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    uint256 public totalDebtCeiling;
    uint256 public totalDebt;

    struct LiquiditySourceHandler {
        uint256 debtCeiling;
        uint256 debt;
        address handler;
        bool paused;
    }

    /**
     * @dev Mapping of valid liquidity sources. Apart from being listed, it also MUST have a valid `handler` contract and SHOULD NOT be paused.
     *
     * A `handler.debtCeiling` per liquidity source is implemented which its sum MUST add to `totalDebtCeiling` as well as `handler.debt` and `totalDebt`
     */
    mapping(address liquiditySource => LiquiditySourceHandler) public liquiditySources;

    mapping(bytes32 => uint256) public deposits;
    mapping(bytes32 => address) public depositIDtoDepositor;

    /**
     * @dev Events
     */

    event Deposit(
        address indexed liquiditySource, address indexed depositor, uint256 indexed positionID, uint256 amount
    );

    event Withdraw(
        address indexed liquiditySource, address indexed depositor, uint256 indexed positionID, uint256 amount
    );

    event AddLiquiditySource(address indexed liquiditySource, address indexed handler);

    event RemoveLiquiditySource(address indexed liquiditySource);

    event SetDebtCeiling(address indexed liquiditySource, uint256 debtCeiling, bool paused);

    /**
     * @dev CustomErrors
     */

    error TChokeInvalidLiquidityPosition(address liquiditySource);
    error TChokeInvalidDeposit(bytes32);
    error TChokeInvalidHandler();
    error TChokeDebtCeilingExceeded();
    error TChokePaused();

    function initialize(uint256 initialSupply) public initializer {
        __ReentrancyGuard_init();
        __AccessControl_init();
        __ERC20_init("tChoke", "tChoke");
        __ERC20Burnable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(LIQUIDITY_MANAGER_ROLE, msg.sender);
        _grantRole(DEBT_MANAGER_ROLE, msg.sender);

        _mint(msg.sender, initialSupply);
    }

    /**
     * @dev To be executed by any user with `LIQUIDITY_MANAGER` permission.
     * Previous handler must have been removed if existing, which in turn must have the handlers' debt fully paid.
     * @param liquiditySource Any address representing underlying liquidity. How liquidity is managed or liquidated is up to handler. Debt ceiling must be set per liquidity source.
     * @param handler MUST implement `handleDeposit` and `handleWithdraw` in its interface. Is up to the handler contract to return the proper amount of tChoke corresponding to each liquidity source and how `depositID` is calculated.
     *
     * Emits a {AddLiquiditySource} event.
     *
     */

    function addLiquiditySource(address liquiditySource, address handler) external onlyRole(LIQUIDITY_MANAGER_ROLE) {
        if (
            handler == address(0) || liquiditySource == address(0)
                || liquiditySources[liquiditySource].handler != address(0) || liquiditySources[liquiditySource].debt != 0
        ) revert TChokeInvalidHandler();

        liquiditySources[liquiditySource] = LiquiditySourceHandler(0, 0, handler, false);

        emit AddLiquiditySource(liquiditySource, handler);
    }

    /**
     * @dev To be executed by any user with `LIQUIDITY_MANAGER` permission.
     * Removing any liquiditySource must be consistent with `totalDebt` and `totalDebtCeiling`
     * In order to ensure liquidity parameters invariant, `handler.debt` and `handler.debtCeiling` MUST be zero.
     * @param liquiditySource Any address representing underlying liquidity previously added using {addLiquiditySource}.
     *
     * Emits a {RemoveLiquiditySource} event.
     *
     */

    function removeLiquiditySource(address liquiditySource) external onlyRole(LIQUIDITY_MANAGER_ROLE) {
        if (
            liquiditySources[liquiditySource].handler == address(0) || liquiditySources[liquiditySource].debt != 0
                || liquiditySources[liquiditySource].debtCeiling != 0
        ) revert TChokeInvalidHandler();

        liquiditySources[liquiditySource] = LiquiditySourceHandler(0, 0, address(0), false);

        emit RemoveLiquiditySource(liquiditySource);
    }

    /**
     * @dev To be executed by any user with `DEBT_MANAGER` permission.
     * Single entrypoint for modifying totalDebtCeiling.
     * In order to ensure liquidity parameters invariant, `handler.debt` and `handler.debtCeiling` MUST be zero.
     * @param liquiditySource Any address representing underlying liquidity previously added using {addLiquiditySource}.
     * @param _debtCeiling New `debtCeiling` for specified `liquiditySource`. Previous `handler.debtCeiling` will be substracted from `totalDebtCeiling` first.
     * @param _paused Will pause liquiditySource and disable depositing for that specific source.
     *
     * Emits a {SetDebtCeiling} event.
     */

    function setDebtCeiling(address liquiditySource, uint256 _debtCeiling, bool _paused)
        external
        onlyRole(DEBT_MANAGER_ROLE)
    {
        if (liquiditySources[liquiditySource].handler == address(0)) {
            revert TChokeInvalidHandler();
        }

        totalDebtCeiling = totalDebtCeiling - liquiditySources[liquiditySource].debtCeiling;

        liquiditySources[liquiditySource].debtCeiling = _debtCeiling;

        totalDebtCeiling = totalDebtCeiling + _debtCeiling;

        liquiditySources[liquiditySource].paused = _paused;

        emit SetDebtCeiling(liquiditySource, _debtCeiling, _paused);
    }

    /**
     * @dev Generic method for depositing various liquidity sources and minting the corresponding amount of tChoke.
     * Considering any active debt, the handler and total debt cannot exceed either `handler.debtCeiling` or `totalDebtCeiling`.
     *
     * Each deposit must have a unique bytes32 `depositID` which is stored along the debt as receipt of the corresponding liquidity.
     *
     * Emits a {Deposit} event.
     */

    function deposit(address liquiditySource, uint256 positionID) external nonReentrant {
        if (totalDebt > totalDebtCeiling) revert TChokeDebtCeilingExceeded();

        LiquiditySourceHandler storage handler = liquiditySources[liquiditySource];

        if (
            liquiditySource == address(0) || handler.handler == address(0) || positionID == 0
                || handler.debt > handler.debtCeiling
        ) revert TChokeInvalidLiquidityPosition(liquiditySource);

        if (handler.paused) revert TChokePaused();

        ITPumpHandler tChokeHandler = ITPumpHandler(handler.handler);

        (bytes32 depositID, uint256 tChokeAmount) =
            tChokeHandler.handleDeposit(liquiditySource, _msgSender(), positionID);

        if (tChokeAmount == 0 || deposits[depositID] != 0 || depositIDtoDepositor[depositID] != address(0)) {
            revert TChokeInvalidLiquidityPosition(liquiditySource);
        }

        if ((totalDebt + tChokeAmount) > totalDebtCeiling || (handler.debt + tChokeAmount) > handler.debtCeiling) {
            revert TChokeDebtCeilingExceeded();
        }

        deposits[depositID] = tChokeAmount;

        totalDebt = totalDebt + tChokeAmount;
        handler.debt = handler.debt + tChokeAmount;
        depositIDtoDepositor[depositID] = _msgSender();

        _mint(_msgSender(), tChokeAmount);

        emit Deposit(liquiditySource, _msgSender(), positionID, tChokeAmount);
    }

    /**
     * @dev Method for withdrawing any liquidity representation from the `handler` vault, which must ensure that the liquidity is in fact transferred. It relies on the _burn mechanism of {ERC20} which decreases _totalSupply and reverts in case _msgSender() does not have enough balance.
     * It also expects to find _msgSender() -depositor- associated with `depositID` for redundancy.
     *
     * Emits a {Deposit} event.
     *
     * NOTE: Debts are per account-basis. The actual debt does not depend nor varies with the usd value of the underlying. It is only calculated when deposited and not recalculated during `withdraw`.
     *
     */

    function withdraw(address liquiditySource, uint256 positionID) external nonReentrant {
        LiquiditySourceHandler storage handler = liquiditySources[liquiditySource];

        if (handler.handler == address(0) || positionID == 0) {
            revert TChokeInvalidLiquidityPosition(liquiditySource);
        }

        ITPumpHandler tChokeHandler = ITPumpHandler(handler.handler);

        bytes32 depositID = tChokeHandler.handleWithdraw(liquiditySource, _msgSender(), positionID);

        uint256 tChokeAmount = deposits[depositID];
        if (tChokeAmount == 0 || depositIDtoDepositor[depositID] != _msgSender()) {
            revert TChokeInvalidDeposit(depositID);
        }

        _burn(_msgSender(), tChokeAmount);

        deposits[depositID] = 0;

        totalDebt = totalDebt - tChokeAmount;
        handler.debt = handler.debt - tChokeAmount;
        depositIDtoDepositor[depositID] = address(0);

        emit Withdraw(liquiditySource, _msgSender(), positionID, tChokeAmount);
    }

    function isUSDC(address token) external pure returns (bool) {
        return token == USDCe || token == USDC;
    }
}
