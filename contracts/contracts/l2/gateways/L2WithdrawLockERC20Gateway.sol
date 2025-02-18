// SPDX-License-Identifier: MIT

pragma solidity =0.8.24;

import {IL2ERC20Gateway, L2ERC20Gateway} from "./L2ERC20Gateway.sol";
import {IL2CrossDomainMessenger} from "../IL2CrossDomainMessenger.sol";
import {IL1ERC20Gateway} from "../../l1/gateways/IL1ERC20Gateway.sol";
import {GatewayBase} from "../../libraries/gateway/GatewayBase.sol";
import {IMorphERC20Upgradeable} from "../../libraries/token/IMorphERC20Upgradeable.sol";

/// @title L2WithdrawLockERC20Gateway
/// @notice The `L2WithdrawLockERC20Gateway` is used to withdraw custom ERC20 compatible tokens on layer 2 and
/// finalize deposit the tokens from layer 1.
contract L2WithdrawLockERC20Gateway is L2ERC20Gateway {
    /**********
     * Events *
     **********/

    /// @notice Emitted when token mapping for ERC20 token is updated.
    /// @param l2Token The address of corresponding ERC20 token in layer 2.
    /// @param oldL1Token The address of the old corresponding ERC20 token in layer 1.
    /// @param newL1Token The address of the new corresponding ERC20 token in layer 1.
    event UpdateTokenMapping(address indexed l2Token, address indexed oldL1Token, address indexed newL1Token);

    /// @dev Emitted when the withdrawal lock status for an L2 token is updated.
    /// @param l2Token The address of the L2 token.
    /// @param lock The new lock status.
    event UpdateWithdrawLock(address indexed l2Token, bool lock);

    /*************
     * Variables *
     *************/

    /// @notice Mapping from layer 2 token address to layer 1 token address for ERC20 token.
    mapping(address => address) public tokenMapping;

    mapping(address => bool) public withdrawLock;

    /***************
     * Constructor *
     ***************/

    constructor() {
        _disableInitializers();
    }

    function initialize(address _counterpart, address _router, address _messenger) external initializer {
        require(_router != address(0), "zero router address");

        GatewayBase._initialize(_counterpart, _router, _messenger);
    }

    /*************************
     * Public View Functions *
     *************************/

    /// @inheritdoc IL2ERC20Gateway
    function getL1ERC20Address(address _l2Token) external view override returns (address) {
        return tokenMapping[_l2Token];
    }

    /// @inheritdoc IL2ERC20Gateway
    function getL2ERC20Address(address) public pure override returns (address) {
        revert("unimplemented");
    }

    /*****************************
     * Public Mutating Functions *
     *****************************/

    /// @inheritdoc IL2ERC20Gateway
    function finalizeDepositERC20(
        address _l1Token,
        address _l2Token,
        address _from,
        address _to,
        uint256 _amount,
        bytes calldata _data
    ) external payable override onlyCallByCounterpart nonReentrant {
        require(msg.value == 0, "nonzero msg.value");
        require(_l1Token != address(0), "token address cannot be 0");
        require(_l1Token == tokenMapping[_l2Token], "l1 token mismatch");

        IMorphERC20Upgradeable(_l2Token).mint(_to, _amount);

        _doCallback(_to, _data);

        emit FinalizeDepositERC20(_l1Token, _l2Token, _from, _to, _amount, _data);
    }

    /************************
     * Restricted Functions *
     ************************/

    /// @notice Update layer 2 to layer 1 token mapping and .
    /// @param _l2Token The address of corresponding ERC20 token on layer 2.
    /// @param _l1Token The address of ERC20 token on layer 1.
    function updateTokenMapping(address _l2Token, address _l1Token) external onlyOwner {
        require(_l1Token != address(0), "token address cannot be 0");

        address _oldL1Token = tokenMapping[_l2Token];
        tokenMapping[_l2Token] = _l1Token;
        withdrawLock[_l2Token] = true;

        emit UpdateTokenMapping(_l2Token, _oldL1Token, _l1Token);
    }

    /// @dev Updates the withdrawal lock status for a specific L2 token.
    /// @param _l2Token The address of the L2 token.
    /// @param _lock The new lock status to be set.
    function updateWithdrawLock(address _l2Token, bool _lock) external onlyOwner {
        require(_l2Token != address(0), "token address cannot be 0");

        withdrawLock[_l2Token] = _lock;

        emit UpdateWithdrawLock(_l2Token, _lock);
    }

    /**********************
     * Internal Functions *
     **********************/

    /// @inheritdoc L2ERC20Gateway
    function _withdraw(
        address _token,
        address _to,
        uint256 _amount,
        bytes memory _data,
        uint256 _gasLimit
    ) internal virtual override nonReentrant {
        require(!withdrawLock[_token], "withdraw lock");
        address _l1Token = tokenMapping[_token];
        require(_l1Token != address(0), "no corresponding l1 token");

        require(_amount > 0, "withdraw zero amount");

        // 1. Extract real sender if this call is from L2GatewayRouter.
        address _from = _msgSender();
        if (router == _from) {
            (_from, _data) = abi.decode(_data, (address, bytes));
        }

        // 2. Burn token.
        IMorphERC20Upgradeable(_token).burn(_from, _amount);

        // 3. Generate message passed to L1StandardERC20Gateway.
        bytes memory _message = abi.encodeCall(
            IL1ERC20Gateway.finalizeWithdrawERC20,
            (_l1Token, _token, _from, _to, _amount, _data)
        );

        uint256 nonce = IL2CrossDomainMessenger(messenger).messageNonce();
        // 4. send message to L2MorphMessenger
        IL2CrossDomainMessenger(messenger).sendMessage{value: msg.value}(counterpart, 0, _message, _gasLimit);

        emit WithdrawERC20(_l1Token, _token, _from, _to, _amount, _data, nonce);
    }
}
