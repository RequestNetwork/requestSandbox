pragma solidity 0.4.18;

import '../core/RequestCore.sol';
import './extensions/RequestSynchroneInterface.sol';
import '../base/math/SafeMath.sol';

/**
 * @title RequestEthereum
 *
 * @dev RequestEthereum is the sub contract managing the request payed in Ethereum
 *
 * @dev Requests can be created by the Payee with createRequest() or by the payer from a request signed offchain by the payee with createQuickRequest
 * @dev Requests can have 1 extension. it has to implement RequestSynchroneInterface and declared trusted on the Core
 */
contract RequestEthereum {
    using SafeMath for uint;

    // RequestCore object
    RequestCore public requestCore;

    // Ethereum available to withdraw
    struct EthToWithdraw {
        uint amount;
        address recipient;
    }
    mapping(address => uint) public ethToWithdraw;

    /*
     * @dev Constructor
     * @param _requestCoreAddress Request Core address
     */  
    function RequestEthereum(address _requestCoreAddress) public
    {
        requestCore=RequestCore(_requestCoreAddress);
    }

    /*
     * @dev Function to create a request 
     *
     * @dev msg.sender must be _payee or _payer
     *
     * @param _payee Entity which will receive the payment
     * @param _payer Entity supposed to pay
     * @param _amountInitial Initial amount initial to be received. This amount can't be changed.
     * @param _extension an extension can be linked to a request and allows advanced payments conditions such as escrow. Extensions have to be whitelisted in Core
     * @param _extensionParams Parameters for the extensions. It is an array of 9 bytes32.
     *
     * @return Returns the id of the request 
     */
    function createRequest(address _payee, address _payer, uint _amountInitial, address _extension, bytes32[9] _extensionParams)
        external
        condition(msg.sender==_payee || msg.sender==_payer)
        returns(uint)
    {
        uint requestId= requestCore.createRequest(msg.sender, _payee, _payer, _amountInitial, _extension);

        if(_extension!=0) {
            RequestSynchroneInterface extension = RequestSynchroneInterface(_extension);
            extension.createRequest(requestId, _extensionParams);
        }

        return requestId;
    }

    /*
     * @dev Function to broadcast and accept an offchain signed request (can be paid and tips also)
     *
     * @dev msg.sender must be _payer
     * @dev the _payer can tips 
     *
     * @param _payee Entity which will receive the payment
     * @param _payer Entity supposed to pay
     * @param _amountInitial Initial amount initial to be received. This amount can't be changed.
     * @param _extension an extension can be linked to a request and allows advanced payments conditions such as escrow. Extensions have to be whitelisted in Core
     * @param _extensionParams Parameters for the extension. It is an array of 9 bytes32
     * @param _tips amount of tips the payer want to declare
     * @param v ECDSA signature parameter v.
     * @param r ECDSA signature parameters r.
     * @param s ECDSA signature parameters s.
     *
     * @return Returns the id of the request 
     */
   function createQuickRequest(address _payee, address _payer, uint _amountInitial, address _extension, bytes32[9] _extensionParams, uint _tips, uint8 v, bytes32 r, bytes32 s)
        external
        payable
        returns(uint)
    {
        require(msg.sender==_payer);
        require(msg.value >= _tips); // tips declare must be lower than amount sent
        require(_amountInitial.add(_tips) >= msg.value); // You cannot pay more than amount needed
    
        bytes32 hash = getRequestHash(_payee,_payer,_amountInitial,_extension,_extensionParams);

        // check the signature
        require(isValidSignature(_payee, hash, v, r, s));

        uint requestId=requestCore.createRequest(msg.sender, _payee, _payer, _amountInitial, _extension);

        if(_extension!=0) {
            RequestSynchroneInterface extension = RequestSynchroneInterface(_extension);
            extension.createRequest(requestId, _extensionParams);
        }

        // accept must succeed
        require(acceptInternal(requestId));

        if(_tips > 0) {
            addAdditionalInternal(requestId, _tips);
        }
        if(msg.value > 0) {
            paymentInternal(requestId, msg.value);
        }

        return requestId;
    }

    // ---- INTERFACE FUNCTIONS ------------------------------------------------------------------------------------

    /*
     * @dev Function to accept a request
     *
     * @dev msg.sender must be _payer or an extension used by the request
     *
     * @param _requestId id of the request 
     *
     * @return true if the request is accepted, false otherwise
     */
    function accept(uint _requestId) 
        external
        condition(isOnlyRequestExtension(_requestId) || (requestCore.getPayer(_requestId)==msg.sender && requestCore.getState(_requestId)==RequestCore.State.Created))
        returns(bool)
    {
        return acceptInternal(_requestId);
    }

    /*
     * @dev Function to decline a request
     *
     * @dev msg.sender must be _payer or the extension used by the request
     *
     * @param _requestId id of the request 
     *
     * @return true if the request is declined, false otherwise
     */
    function decline(uint _requestId)
        external
        condition(isOnlyRequestExtension(_requestId) || (requestCore.getPayer(_requestId)==msg.sender && requestCore.getState(_requestId)==RequestCore.State.Created))
        returns(bool)
    {
        address extensionAddr = requestCore.getExtension(_requestId);

        bool isOK = true;
        if(extensionAddr!=0 && extensionAddr!=msg.sender)  
        {
            RequestSynchroneInterface extension = RequestSynchroneInterface(extensionAddr);
            isOK = extension.decline(_requestId);
        }

        if(isOK) 
        {
            requestCore.decline(_requestId);
        }  
        return isOK;
    }

    /*
     * @dev Function to declare a payment a request
     *
     * @dev msg.sender must be an extension used by the request
     *
     * @param _requestId id of the request 
     * @param _amount amount of the payment to declare
     *
     * @return true if the payment is declared, false otherwise
     */
    function payment(uint _requestId, uint _amount)
        external
        onlyRequestExtensions(_requestId)
        returns(bool)
    {
        return paymentInternal(_requestId, _amount);
    }

    /*
     * @dev Function to order a fund mouvment 
     *
     * @dev msg.sender must be an extension used by the request
     *
     * @param _requestId id of the request 
     * @param _recipient adress where the wei has to me send to
     * @param _amount amount in wei to send
     *
     * @return true if the fund mouvement is done, false otherwise
     */
    function fundOrder(uint _requestId, address _recipient, uint _amount)
        external
        onlyRequestExtensions(_requestId)
        returns(bool)
    {
        return fundOrderInternal(_requestId, _recipient, _amount);
    }

    /*
     * @dev Function to cancel a request
     *
     * @dev msg.sender must be _payee or an extension used by the request
     * @dev only request with amountPaid equals to zero can be cancel
     *
     * @param _requestId id of the request 
     *
     * @return true if the request is canceled, false otherwise
     */
    function cancel(uint _requestId)
        external
        condition(isOnlyRequestExtension(_requestId) || (requestCore.getPayee(_requestId)==msg.sender && (requestCore.getState(_requestId)==RequestCore.State.Created || requestCore.getState(_requestId)==RequestCore.State.Accepted)))
        returns(bool)
    {
        // impossible to cancel a Request with a balance != 0
        require(requestCore.getAmountPaid(_requestId) == 0);

        address extensionAddr = requestCore.getExtension(_requestId);

        bool isOK = true;
        if(extensionAddr!=0 && extensionAddr!=msg.sender)  
        {
            RequestSynchroneInterface extension = RequestSynchroneInterface(extensionAddr);
            isOK = extension.cancel(_requestId);
        }
        
        if(isOK) 
        {
          requestCore.cancel(_requestId);
        }
        return isOK;
    }

    // ----------------------------------------------------------------------------------------


    // ---- CONTRACT FUNCTIONS ------------------------------------------------------------------------------------
    /*
     * @dev Function PAYABLE to pay in ether a request
     *
     * @dev the request must be accepted
     * @dev tips must be lower than the actual amount of wei sent
     *
     * @param _requestId id of the request
     * @param _tips amount of tips in wei to declare 
     */
    function pay(uint _requestId, uint _tips)
        external
        payable
        condition(requestCore.getState(_requestId)==RequestCore.State.Accepted)
        condition(msg.value >= _tips) // tips declare must be lower than amount sent
        condition(requestCore.getAmountInitialAfterSubAdd(_requestId).add(_tips) >= msg.value) // You can pay more than amount needed
    {
        if(_tips > 0) {
            addAdditionalInternal(_requestId, _tips);
        }
        paymentInternal(_requestId, msg.value);
    }

    /*
     * @dev Function PAYABLE to pay back in ether a request to the payee
     *
     * @dev msg.sender must be _payer
     * @dev the request must be accepted
     * @dev the payback must be lower than the amount already paid for the request
     *
     * @param _requestId id of the request
     */
    function payback(uint _requestId)
        external
        condition(requestCore.getState(_requestId)==RequestCore.State.Accepted)
        onlyRequestPayee(_requestId)
        condition(msg.value <= requestCore.getAmountPaid(_requestId))
        payable
    {   
        // we cannot refund more than already paid
        refundInternal(_requestId, msg.value);
    }

    /*
     * @dev Function to declare a discount
     *
     * @dev msg.sender must be _payee or an extension used by the request
     * @dev the request must be accepted or created
     *
     * @param _requestId id of the request
     * @param _tips amount of discount in wei to declare 
     */
    function discount(uint _requestId, uint _amount)
        public
        condition(requestCore.getState(_requestId)==RequestCore.State.Accepted || requestCore.getState(_requestId)==RequestCore.State.Created)
        onlyRequestPayee(_requestId)
        condition(_amount.add(requestCore.getAmountPaid(_requestId)) <= requestCore.getAmountInitialAfterSubAdd(_requestId))
    {
        addSubtractInternal(_requestId, _amount);
    }


    /*
     * @dev Function to withdraw ether
     */
    function withdraw()
        public
    {
        uint amount = ethToWithdraw[msg.sender];
        ethToWithdraw[msg.sender] = 0;
        msg.sender.transfer(amount);
    }
    // ----------------------------------------------------------------------------------------


    // ---- INTERNAL FUNCTIONS ------------------------------------------------------------------------------------
    /*
     * @dev Function internal to manage payment declaration
     *
     * @param _requestId id of the request
     * @param _amount amount of payment in wei to declare 
     *
     * @return true if the payment is done, false otherwise
     */
    function paymentInternal(uint _requestId, uint _amount) 
        internal
        returns(bool)
    {
        address extensionAddr = requestCore.getExtension(_requestId);

        bool isOK = true;
        if(extensionAddr!=0 && extensionAddr!=msg.sender) 
        {
            RequestSynchroneInterface extension = RequestSynchroneInterface(extensionAddr);
            isOK = extension.payment(_requestId, _amount);
        }

        if(isOK) 
        {
            requestCore.payment(_requestId, _amount);
            // payment done, the money is ready to withdraw by the payee
            fundOrderInternal(_requestId, requestCore.getPayee(_requestId), _amount);
        }
        return isOK;
    }

    /*
     * @dev Function internal to manage discount declaration
     *
     * @param _requestId id of the request
     * @param _amount amount of discount in wei to declare 
     *
     * @return true if the discount is declared, false otherwise
     */
    function addSubtractInternal(uint _requestId, uint _amount) 
        internal
        returns(bool)
    {
        address extensionAddr = requestCore.getExtension(_requestId);

        bool isOK = true;
        if(extensionAddr!=0 && extensionAddr!=msg.sender)  
        {
            RequestSynchroneInterface extension = RequestSynchroneInterface(extensionAddr);
            isOK = extension.addSubtract(_requestId, _amount);
        }

        if(isOK) 
        {
            requestCore.addSubtract(_requestId, _amount);
        }
        return isOK;
    }

    /*
     * @dev Function internal to manage tips declaration
     *
     * @param _requestId id of the request
     * @param _amount amount of tips in wei to declare 
     *
     * @return true if the tips is declared, false otherwise
     */
    function  addAdditionalInternal(uint _requestId, uint _amount) 
        internal
        returns(bool)
    {
        address extensionAddr = requestCore.getExtension(_requestId);

        bool isOK = true;
        if(extensionAddr!=0 && extensionAddr!=msg.sender)  
        {
            RequestSynchroneInterface extension = RequestSynchroneInterface(extensionAddr);
            isOK = extension.addAdditional(_requestId, _amount);
        }

        if(isOK) 
        {
            requestCore.addAdditional(_requestId, _amount);
        }
        return isOK;
    }

    /*
     * @dev Function internal to manage refund declaration
     *
     * @param _requestId id of the request
     * @param _amount amount of refund in wei to declare 
     *
     * @return true if the refund is done, false otherwise
     */
    function refundInternal(uint _requestId, uint _amount) 
        internal
        onlyRequestState(_requestId, RequestCore.State.Accepted)
        returns(bool)
    {
        address extensionAddr = requestCore.getExtension(_requestId);

        bool isOK = true;
        if(extensionAddr!=0 && extensionAddr!=msg.sender)  
        {
            RequestSynchroneInterface extension = RequestSynchroneInterface(extensionAddr);
            isOK = extension.refund(_requestId, _amount);
        }

        if(isOK) 
        {
            requestCore.refund(_requestId, _amount);
            // refund done, the money is ready to withdraw by the payer
            fundOrderInternal(_requestId, requestCore.getPayer(_requestId), _amount);
        }
    }

    /*
     * @dev Function internal to manage fund mouvement
     *
     * @param _requestId id of the request 
     * @param _recipient adress where the wei has to me send to
     * @param _amount amount in wei to send
     *
     * @return true if the fund mouvement is done, false otherwise
     */
    function fundOrderInternal(uint _requestId, address _recipient, uint _amount) 
        internal
        returns(bool)
    {
        address extensionAddr = requestCore.getExtension(_requestId);

        bool isOK = true;
        if(extensionAddr!=0 && extensionAddr!=msg.sender)  
        {
            RequestSynchroneInterface extension = RequestSynchroneInterface(extensionAddr);
            isOK = extension.fundOrder(_requestId,_recipient,_amount);
        }

        if(isOK) 
        {
            // sending fund means make it availbale to withdraw here
            ethToWithdraw[_recipient] += _amount;
        }   
        return isOK;
    }

    /*
     * @dev Function internal to manage acceptance
     *
     * @param _requestId id of the request 
     *
     * @return true if the request is accept, false otherwise
     */
    function acceptInternal(uint _requestId) 
        internal
        returns(bool)
    {
        address extensionAddr = requestCore.getExtension(_requestId);

        bool isOK = true;
        if(extensionAddr!=0 && extensionAddr!=msg.sender)  
        {
            RequestSynchroneInterface extension = RequestSynchroneInterface(requestCore.getExtension(_requestId));
            isOK = extension.accept(_requestId);
        }

        if(isOK) 
        {
            requestCore.accept(_requestId);
        }  
        return isOK;
    }

    /*
     * @dev Function internal to calculate Keccak-256 hash of a request with specified parameters
     *
     * @param _payee Entity which will receive the payment
     * @param _payer Entity supposed to pay
     * @param _amountInitial Initial amount initial to be received. This amount can't be changed.
     * @param _extensions Up to 3 extensions can be linked to a request and allows advanced payments conditions such as escrow. Extensions have to be whitelisted in Core
     * @param _extensionParams Parameters for the extensions. It is an array of 9 bytes32, the 3 first element are for the first extension, the 3 next for the second extension and the last 3 for the third extension.
     *
     * @return Keccak-256 hash of a request
     */
    function getRequestHash(address _payee, address _payer, uint _amountInitial, address _extension, bytes32[9] _extensionParams)
        internal
        view
        returns(bytes32)
    {
        return keccak256(this,_payee,_payer,_amountInitial,_extension,_extensionParams);
    }

    /*
     * @dev Verifies that a hash signature is valid. 0x style
     * @param signer address of signer.
     * @param hash Signed Keccak-256 hash.
     * @param v ECDSA signature parameter v.
     * @param r ECDSA signature parameters r.
     * @param s ECDSA signature parameters s.
     * @return Validity of order signature.
     */
    function isValidSignature(
        address signer,
        bytes32 hash,
        uint8 v,
        bytes32 r,
        bytes32 s)
        public
        pure
        returns (bool)
    {
        return signer == ecrecover(
            keccak256("\x19Ethereum Signed Message:\n32", hash),
            v,
            r,
            s
        );
    }

    /*
     * @dev Function internal to check if the msg.sender is an extension of the request
     *
     * @param _requestId id of the request 
     *
     * @return true if msg.sender is an extension of the request
     */
    function isOnlyRequestExtension(uint _requestId) 
        internal 
        view
        returns(bool)
    {
        return msg.sender==requestCore.getExtension(_requestId);
    }

    //modifier
    modifier condition(bool c) 
    {
        require(c);
        _;
    }

    /*
     * @dev Modifier to check if msg.sender is payer
     * @dev Revert if msg.sender is not payer
     * @param _requestId id of the request 
     */    
    modifier onlyRequestPayer(uint _requestId) 
    {
        require(requestCore.getPayer(_requestId)==msg.sender);
        _;
    }
    
    /*
     * @dev Modifier to check if msg.sender is payee
     * @dev Revert if msg.sender is not payee
     * @param _requestId id of the request 
     */    
    modifier onlyRequestPayee(uint _requestId) 
    {
        require(requestCore.getPayee(_requestId)==msg.sender);
        _;
    }

    /*
     * @dev Modifier to check if msg.sender is payee or payer
     * @dev Revert if msg.sender is not payee or payer
     * @param _requestId id of the request 
     */
    modifier onlyRequestPayeeOrPayer(uint _requestId) 
    {
        require(requestCore.getPayee(_requestId)==msg.sender || requestCore.getPayer(_requestId)==msg.sender);
        _;
    }

    /*
     * @dev Modifier to check if request is in a specify state
     * @dev Revert if request not in a specify state
     * @param _requestId id of the request 
     * @param _state state to check
     */
    modifier onlyRequestState(uint _requestId, RequestCore.State _state) 
    {
        require(requestCore.getState(_requestId)==_state);
        _;
    }

    /*
     * @dev Modifier to check if the msg.sender is an extension of the request
     * @dev Revert if msg.sender is not an extension of the request
     * @param _requestId id of the request
     */
    modifier onlyRequestExtensions(uint _requestId) 
    {
        require(isOnlyRequestExtension(_requestId));
        _;
    }
}
