// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./TPump.sol";

interface ITPumpHandlerV2 {
    function handleDeposit(address liquiditySource, address from, uint256 positionID)
        external
        returns (bytes32 depositID, uint256 tChokeAmount);

    function handleWithdraw(address liquiditySource, address to, uint256 positionID)
        external
        returns (bytes32 depositID);

    function liquidate(address source, uint256 positionID, address owner, address liquidator)
        external
        returns (bool, bytes32, uint256);
}

contract TPumpV2 is TPump {
    error TChokeInvalidLiquidation();

    event Liquidate(
        address indexed liquiditySource,
        address indexed owner,
        address indexed liquidator,
        uint256 positionID,
        uint256 amount
    );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initializeV2() public reinitializer(2) {}

    /**
     * @dev Method for liquidating any liquidity position from the `handler` vault, which must ensure that the liquidity is in fact transferred. It relies on the _burn mechanism of {ERC20} which decreases _totalSupply and reverts in case _msgSender() -liquidator- does not have enough balance.
     * It also expects to find owner -depositor- associated with `depositID` for redundancy.
     *
     * Emits a {Liquidate} event.
     *
     */
    function liquidate(address source, uint256 positionID, address owner) external nonReentrant {
        LiquiditySourceHandler storage handler = liquiditySources[source];

        if (handler.handler == address(0)) revert TChokeInvalidHandler();

        if (handler.paused) revert TChokePaused();

        ITPumpHandlerV2 tChokeHandler = ITPumpHandlerV2(handler.handler);
        (bool success, bytes32 depositID, uint256 tChokeAmount) =
            tChokeHandler.liquidate(source, positionID, owner, msg.sender);

        if (!success || depositID == bytes32(0) || tChokeAmount == 0) revert TChokeInvalidLiquidation();
        if (depositIDtoDepositor[depositID] != owner || deposits[depositID] != tChokeAmount) {
            revert TChokeInvalidDeposit(depositID);
        }

        _burn(_msgSender(), tChokeAmount);

        deposits[depositID] = 0;

        totalDebt = totalDebt - tChokeAmount;
        handler.debt = handler.debt - tChokeAmount;
        depositIDtoDepositor[depositID] = address(0);

        emit Liquidate(source, owner, msg.sender, positionID, tChokeAmount);
    }
}
