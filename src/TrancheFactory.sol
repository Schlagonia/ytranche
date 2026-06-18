// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {TrancheStrategy} from "./TrancheStrategy.sol";
import {LockedTrancheStrategy} from "./LockedTrancheStrategy.sol";
import {ITrancheStrategy} from "./interfaces/ITrancheStrategy.sol";

/// @notice Factory for atomic and cooldown-gated Tranche deployments.
contract TrancheFactory {
    event NewTrancheStrategy(
        address indexed tranche, address indexed asset, address indexed controller, address hook, address governance
    );
    event NewLockedTrancheStrategy(
        address indexed tranche,
        address indexed asset,
        address indexed controller,
        address hook,
        address governance,
        uint256 cooldownDuration,
        uint256 withdrawalWindow
    );

    address public immutable EMERGENCY_ADMIN;
    address public immutable GOVERNANCE;

    address public management;
    address public performanceFeeRecipient;
    address public keeper;

    mapping(address => bool) public isDeployedTranche;
    mapping(address => bool) public isDeployedLockedTranche;

    constructor(
        address _management,
        address _performanceFeeRecipient,
        address _keeper,
        address _emergencyAdmin,
        address _governance
    ) {
        require(
            _management != address(0) && _performanceFeeRecipient != address(0) && _governance != address(0), "ZERO"
        );
        management = _management;
        performanceFeeRecipient = _performanceFeeRecipient;
        keeper = _keeper;
        EMERGENCY_ADMIN = _emergencyAdmin;
        GOVERNANCE = _governance;
    }

    function newTrancheStrategy(address _asset, string calldata _name, address _controller, address _hook)
        external
        returns (address)
    {
        ITrancheStrategy tranche =
            ITrancheStrategy(address(new TrancheStrategy(_asset, _name, _controller, _hook, GOVERNANCE)));

        _configureStrategy(tranche);
        isDeployedTranche[address(tranche)] = true;

        emit NewTrancheStrategy(address(tranche), _asset, _controller, _hook, GOVERNANCE);
        return address(tranche);
    }

    function newLockedTrancheStrategy(
        address _asset,
        string calldata _name,
        address _controller,
        address _hook,
        uint256 _cooldownDuration,
        uint256 _withdrawalWindow
    ) external returns (address) {
        ITrancheStrategy tranche = ITrancheStrategy(
            address(
                new LockedTrancheStrategy(
                    _asset, _name, _controller, _hook, GOVERNANCE, _cooldownDuration, _withdrawalWindow
                )
            )
        );

        _configureStrategy(tranche);
        isDeployedLockedTranche[address(tranche)] = true;

        emit NewLockedTrancheStrategy(
            address(tranche), _asset, _controller, _hook, GOVERNANCE, _cooldownDuration, _withdrawalWindow
        );
        return address(tranche);
    }

    function setAddresses(address _management, address _performanceFeeRecipient, address _keeper) external {
        require(msg.sender == management, "!management");
        require(_management != address(0) && _performanceFeeRecipient != address(0), "ZERO");
        management = _management;
        performanceFeeRecipient = _performanceFeeRecipient;
        keeper = _keeper;
    }

    function _configureStrategy(ITrancheStrategy _strategy) internal {
        _strategy.setKeeper(keeper);
        _strategy.setEmergencyAdmin(EMERGENCY_ADMIN);
        _strategy.setPendingManagement(management);
    }
}
