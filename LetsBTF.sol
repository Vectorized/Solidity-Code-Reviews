//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.9;

import "hardhat/console.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";
import "./royalties/ERC2981ContractWideRoyalties.sol";
import "./EIP712Signature.sol";
import "erc721a/contracts/extensions/ERC721AQueryable.sol";
import "@openzeppelin/contracts/access/AccessControlEnumerable.sol";

error MintNotActive();
error TransferIsLocked();
error MaxSupplyReached();
error MintFundsMismatch();
error TooMuchEthSent();
error AllCreditClaimed();
error InsufficientAvailableCredit();
error CreditClaimFailed();
error NoAmountProvided();
error NoCreditUsed();
error NotApprovedOrOwner();
error TokenDoesNotExist();
error ContractsCantMint();
error InsufficientContractBalance();
error WithdrawFailed();
error WithdrawPercentageIncorrect();
error MintBatchTooHigh();
error MustMintBatchMultiple();
error CreditAlreadySet();
error NothingToWithdraw();
error InitialCreditNotSet();
error NoTokenIdsGiven();

/**
 * @title The first NFT with "built-in" liquidity.
 * @author letsbtf.com
 *
 *
 * Upon minting, Chainlink VRF is used to generate a verifiably 
 * random number of which the credit value is derived from. 
 * Hundreds of simulations were run to determine the best model 
 * for credit distribution, which is as follows 
 * (note: these are weighted probabilities but because a random
 * number is used there will be slight variances to the 
 * actual percentage ratios once the total supply is minted):
 *
 * 19% chance of 0.5 eth credit
 * 17.9% chance of 0.75 eth credit
 * 50% chance of 1 eth credit
 * 10% chance of 1.25 eth credit
 * 3% chance of 1.50 eth credit
 * .10% chance of 10 eth credit
 *
 *
 * #LetsBTF
 *
 */
contract LetsBTF is
    ERC721AQueryable,
    ReentrancyGuard,
    VRFConsumerBaseV2,
    ERC2981ContractWideRoyalties,
    EIP712Signature,
    AccessControlEnumerable
{
    /* =========== MAPPINGS & ARRAYS =========== */

    mapping(uint256 => TokenContainer) public requestIdToTokenId;

    // Don't use this mapping directly if you need to get 
    // the totalCredit and/or claimedCredit
    // for a token externally, use the helper functions 
    // `getTotalCreditForToken`, `getClaimedCreditForToken`
    // and `getAvailableCreditForToken`
    mapping(uint256 => Credit) private tokenCredits;

    /* =========== STRUCTS =========== */

    struct Credit {
        uint256 totalCredit;
        int256 claimedCredit;
        uint256 timestampLastPendingIncrease;
        uint256 lastCreditClaimIndex;
    }

    struct PendingCreditIncrease {
        uint256 amount;
        uint256 timestamp;
    }

    struct TokenContainer {
        // max supply is less than 2**16
        uint16 startId;
        uint16 quantity;
    }

    struct ChainlinkConfig {
        bytes32 keyHash;
        uint64 subId;
        uint32 callbackGasLimit;
        uint16 requestConfirmations;
    }

    /* =========== VARIABLES =========== */

    VRFCoordinatorV2Interface COORDINATOR;
    ChainlinkConfig public chainlinkConfig;

    uint256 public immutable MAX_SUPPLY;
    uint256 public constant MINT_PRICE = 1 ether;
    uint256 public constant MAX_MINT_BATCH = 5;

    uint256 private mintCreditCounter = 1;
    uint256 private fundedAmount;
    uint256 private totalWithdrawedAmount;
    uint256 private devMintSupplyRemaining;

    bool public mintActive;
    string private baseURI;

    uint256 additionalCreditPerCard;

    bytes32 public constant CREDIT_INCREASOR_ROLE = keccak256("CREDIT_INCREASOR_ROLE");

    /* =========== MODIFIERS =========== */

    modifier verifyMintActive() {
        if (!mintActive) {
            revert MintNotActive();
        }
        _;
    }

    modifier amountGreaterThanZero(uint256 _amount) {
        if (_amount < 1) {
            revert NoAmountProvided();
        }
        _;
    }

    modifier verifyTokenNotLocked(uint256 _tokenId) {
        if (isTokenLocked(_tokenId)) {
            revert TransferIsLocked();
        }
        _;
    }

    modifier verifyTokenExists(uint256 _tokenId) {
        if (!_tokenExists(_tokenId)) {
            revert TokenDoesNotExist();
        }
        _;
    }

    modifier isApprovedOrOwner(uint256 tokenId) {
        address owner = ownerOf(tokenId);

        bool approvedOrOwner = (owner == _msgSenderERC721A() ||
            isApprovedForAll(owner, _msgSenderERC721A()) ||
            getApproved(tokenId) == _msgSenderERC721A());
        if (!approvedOrOwner) {
            revert NotApprovedOrOwner();
        }
        _;
    }

    /* =========== EVENTS =========== */

    event MintingStatusUpdated(uint256 indexed _time, bool indexed _value);

    event CreditClaimed(
        uint256 _timestamp,
        uint256 indexed _tokenId,
        uint256 _amountClaimed,
        uint256 _remainingCredit
    );

    event CreditRepaid(
        uint256 _timestamp,
        uint256 indexed _tokenId,
        uint256 _amountRepaid,
        uint256 _remainingCredit
    );

    event CreditIncreased(uint256 _timestamp, uint256 indexed _tokenId, uint256 _amountIncreased);

    event CreditSet(uint256[] _tokenIds, uint256[] _amounts);

    /* =========== CONSTRUCTOR =========== */

    constructor(
        address _vrfCoordinator,
        uint64 _vrfSubId,
        bytes32 _vrfKeyHash,
        uint256 _maxSupply,
        uint256 _devSupply,
        string memory _baseTokenURI
    ) ERC721A("Lets BTF", "LETSBTF") VRFConsumerBaseV2(_vrfCoordinator) {
        COORDINATOR = VRFCoordinatorV2Interface(_vrfCoordinator);
        chainlinkConfig = ChainlinkConfig({
            keyHash: _vrfKeyHash,
            subId: _vrfSubId,
            callbackGasLimit: 1000000,
            requestConfirmations: 10
        });

        MAX_SUPPLY = _maxSupply;
        devMintSupplyRemaining = _devSupply;
        baseURI = _baseTokenURI;

        _setRoyalties(owner(), 500); // 5%

        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(CREDIT_INCREASOR_ROLE, msg.sender);
    }

    function _baseURI() internal view virtual override returns (string memory) {
        return baseURI;
    }

    function _tokenExists(uint256 _tokenId) internal view returns (bool) {
        // Copied from _exists in ERC721A but without the burn check since we aren't
        // doing any token burning
        return _startTokenId() <= _tokenId && _tokenId < _nextTokenId(); // If within bounds
    }

    /* =========== MINTING FUNCTIONS =========== */

    /**
     * @notice Mints tokens to the "treasury" for marketing use, promos, etc.
     * @param _quantity The amount of tokens to mint. 
     *     Must be less than the total remaining dev supply.
     */
    function devMint(uint256 _quantity) external onlyOwner {
        if ((_quantity > devMintSupplyRemaining) || _totalMinted() + _quantity > MAX_SUPPLY) {
            revert MaxSupplyReached();
        }
        if (_quantity % MAX_MINT_BATCH != 0) {
            revert MustMintBatchMultiple();
        }

        unchecked {
            uint256 numBatches = _quantity / MAX_MINT_BATCH;

            for (uint256 i = 0; i < numBatches; i++) {
                _performMint(MAX_MINT_BATCH);
            }

            devMintSupplyRemaining -= _quantity;
        }
    }

    /**
     * @notice Public mint.
     * @param _signature A valid signature generated from our dApp.
     * @param _quantity The amount of tokens to mint.
     * @dev Contracts are not allowed to mint so _safeMint is not needed here.
     */
    function publicMint(bytes calldata _signature, uint256 _quantity)
        external
        payable
        requiresValidSignature(_signature)
    {
        if (!mintActive) {
            revert MintNotActive();
        }
        if (_quantity > MAX_MINT_BATCH) {
            revert MintBatchTooHigh();
        }
        if ((_totalMinted() + devMintSupplyRemaining) + _quantity > MAX_SUPPLY) {
            revert MaxSupplyReached();
        }
        if (msg.value != MINT_PRICE * _quantity) {
            revert MintFundsMismatch();
        }
        if (msg.sender != tx.origin) {
            revert ContractsCantMint();
        }

        _performMint(_quantity);
    }

    /**
     * @dev Performs the actual minting sans any checks 
     * (called by both `devMint` and `publicMint`). 
     * Request for Chainlink VRF is done here and stored in a mapping 
     * for use when the VRF request is fulfilled.
     * @param _quantity The amount of tokens to mint.
     */
    function _performMint(uint256 _quantity) private {
        uint256 startingTokenId = _nextTokenId();
        _mint(msg.sender, _quantity);

        uint256 requestId = COORDINATOR.requestRandomWords(
            chainlinkConfig.keyHash,
            chainlinkConfig.subId,
            chainlinkConfig.requestConfirmations,
            chainlinkConfig.callbackGasLimit,
            1 // numWords
        );

        // type casting and storing in a struct saved ~40% gas in tests
        requestIdToTokenId[requestId] = TokenContainer(uint16(startingTokenId), uint16(_quantity));
    }

    /* =========== SET RANDOM CREDIT AMOUNT =========== */

    /**
     * @dev The meat and potatoes. 
     * This is where the credit is set based off of the random number from Chainlink.
     */
    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords)
        internal
        virtual
        override
    {
        TokenContainer memory container = requestIdToTokenId[requestId];
        delete requestIdToTokenId[requestId];

        uint256 arraySize = uint256(container.quantity);
        uint256[] memory tokenIds = new uint256[](arraySize);
        uint256[] memory amounts = new uint256[](arraySize);

        unchecked {
            // container.quantity will never be greater than 5
            // tokenId will never be greater than MAX_SUPPLY (10000)
            for (uint256 i = 0; i < container.quantity; ++i) {
                uint256 tokenId = container.startId + i;

                uint256 seed = uint256(keccak256(abi.encode(randomWords[0], tokenId))) % 1000;
                tokenIds[i] = tokenId;

                Credit storage credit = tokenCredits[tokenId];
                if (credit.totalCredit == 0) {
                    uint256 cred;

                    if (seed > 0 && seed < 190) {
                        // 19% chance
                        cred = 5000; // 50% credit
                    } else if (seed > 189 && seed < 369) {
                        // 17.9% chance
                        cred = 7500; // 75% credit
                    } else if (seed > 368 && seed < 869) {
                        // 50% chance
                        cred = 10000; // 100% credit
                    } else if (seed > 868 && seed < 969) {
                        // 10% chance
                        cred = 12500; // 125% credit
                    } else if (seed > 968 && seed < 1000) {
                        // 3% chance
                        cred = 15000; // 150% credit
                    } else {
                        // .10%
                        cred = 100000; // 10000% credit
                    }

                    // will never exceed 1E19 (10 ether)
                    credit.totalCredit = (MINT_PRICE * cred) / 10000;
                    // Save user gas during first credit claim
                    // as `claimedCredit` will already be non-zero.
                    credit.claimedCredit = -1;
                    mintCreditCounter += credit.totalCredit;
                    amounts[i] = credit.totalCredit;
                }
            }
        }

        emit CreditSet(tokenIds, amounts);
    }

    /**
     * @dev Fallback that allows us to call this function externally
     * in case of Chainlink issues (edge-case)
     *
     * @param _tokenId The ID of the token to retry the credit set for
     */
    function retryCreditSet(uint256 _tokenId)
        external
        onlyOwner
        nonReentrant
        verifyTokenExists(_tokenId)
    {
        if (tokenCredits[_tokenId].totalCredit > 0) {
            revert CreditAlreadySet();
        }

        uint256 requestId = COORDINATOR.requestRandomWords(
            chainlinkConfig.keyHash,
            chainlinkConfig.subId,
            chainlinkConfig.requestConfirmations,
            chainlinkConfig.callbackGasLimit,
            1 // numWords
        );

        requestIdToTokenId[requestId] = TokenContainer(uint16(_tokenId), uint16(1));
    }

    /**
     * @dev Checks if a token is locked before transfer
     * (via verifyTokenNotLocked modifier), if it is revert.
     */
    function _beforeTokenTransfers(
        address from,
        address to,
        uint256 startTokenId,
        uint256 quantity
    ) internal virtual override verifyTokenNotLocked(startTokenId) {}

    /* =========== CREDIT FUNCTIONS =========== */

    /**
     * @notice Get the available credit amount in wei for a specific token.
     * @param _id The ID of the token
     */
    function getAvailableCreditForToken(uint256 _id) external view returns (uint256) {
        Credit memory credit = tokenCredits[_id];
        return _calculateAvailableCredit(credit.totalCredit, credit.claimedCredit);
    }

    /**
     * @notice Get the total credit amount in wei for a specific token.
     * @param _id The ID of the token
     */
    function getTotalCreditForToken(uint256 _id) external view returns (uint256) {
        return tokenCredits[_id].totalCredit + additionalCreditPerCard;
    }

    /**
     * @notice Get the claimed credit amount in wei for a specific token.
     * @param _id The ID of the token
     */
    function getClaimedCreditForToken(uint256 _id) external view returns (uint256) {
        Credit memory credit = tokenCredits[_id];

        if (credit.claimedCredit < 1) {
            return 0;
        } else {
            return uint256(credit.claimedCredit);
        }
    }

    function _calculateAvailableCredit(uint256 _totalCredit, int256 _claimedCredit)
        internal
        view
        returns (uint256)
    {
        uint256 allCredit = _totalCredit + additionalCreditPerCard;

        if (_claimedCredit < 1) {
            return allCredit;
        } else {
            return allCredit - uint256(_claimedCredit);
        }
    }

    /**
     * @notice Claim credit for a specific token. 
     * The requested amount of credit is sent to the caller 
     * if the caller owns the token
     * and the requested amount to claim is valid.
     *
     * @param _id The ID of the token to claim credit for.
     *
     * @param _amountToClaim The amount of credit to claim
     * (can't be greater than available credit)
     */
    function claimCredit(uint256 _id, uint256 _amountToClaim)
        external
        nonReentrant
        verifyTokenExists(_id)
        isApprovedOrOwner(_id)
        amountGreaterThanZero(_amountToClaim)
    {
        if (address(this).balance < _amountToClaim) {
            revert InsufficientContractBalance();
        }

        Credit storage credit = tokenCredits[_id];

        if (_amountToClaim > _calculateAvailableCredit(credit.totalCredit, credit.claimedCredit)) {
            revert InsufficientAvailableCredit();
        }

        int256 amountToClaim = int256(_amountToClaim);

        // `claimedCredit` will be -1 if there is no credit claimed
        if (credit.claimedCredit < 0) {
            unchecked {
                ++amountToClaim;
            }
        }

        unchecked {
            credit.claimedCredit += amountToClaim;
        }

        (bool success, ) = msg.sender.call{value: _amountToClaim}("");
        if (!success) {
            revert CreditClaimFailed();
        }
    }

    /**
     * @notice Repay credit for a specific token.
     * Caller must own the token and the amount of ether 
     * sent in the message will be the amount that is repaid.
     *
     * @param _id The ID of the token you wish to repay the credit for.
     *
     * @dev If all credit is repaid set the `claimedCredit` value to -1 
     * to prevent the costly operation of setting claimedCredit 
     * from zero to non-zero.
     * A claimed credit of -1 is equivalent to being zero, 
     * aka no credit is currently claimed.
     */
    function repayCredit(uint256 _id)
        external
        payable
        verifyTokenExists(_id)
        isApprovedOrOwner(_id)
        amountGreaterThanZero(msg.value)
    {
        Credit storage credit = tokenCredits[_id];

        if (credit.claimedCredit < 1 || msg.value > uint256(credit.claimedCredit)) {
            revert TooMuchEthSent();
        }

        int256 value = int256(msg.value);
        unchecked {
            if (credit.claimedCredit - value == 0) {
                // Avoid setting claimedCredit back to 0 to save gas (~15k)
                // the next time credit is claimed
                credit.claimedCredit = -1;
            } else {
                credit.claimedCredit -= value;
            }
        }
    }

    /**
     * @notice Determines if a token is locked from being transferred.
     * This is true if any credit is claimed for the token.
     * @param _tokenId The ID of the token to check the lock status of
     */
    function isTokenLocked(uint256 _tokenId) public view returns (bool) {
        return (tokenCredits[_tokenId].claimedCredit > 0);
    }

    /* =========== INCREASING CREDIT FUNCTIONS =========== */

    /**
     * @notice Increase the credit of a specific token by 
     * sending ether to this function
     * @param _id The ID of the token you wish to increase the credit of
     * @dev Anyone can call this function sending ether and 
     *     a token ID to increase the credit - you do not have to own the token.
     */
    function increaseCredit(uint256 _id)
        external
        payable
        amountGreaterThanZero(msg.value)
        verifyTokenExists(_id)
    {
        Credit storage credit = tokenCredits[_id];

        // Initial credit has not yet been set via Chainlink VRF `fulfillRandomWords`
        if (credit.totalCredit == 0) {
            revert InitialCreditNotSet();
        }

        credit.totalCredit += msg.value;

        emit CreditIncreased(block.timestamp, _id, msg.value);
    }

    /**
     * @dev Use this to increase multiple token credits at once.
     * The amount of ether sent will be equally divided amongst
     * the token ID's passed in.
     * @param _ids The IDs of the tokens to increase the credit for
     */
    function increaseCreditBatched(uint256[] calldata _ids)
        external
        payable
        onlyRole(CREDIT_INCREASOR_ROLE)
        amountGreaterThanZero(msg.value)
    {
        if (_ids.length == 0) {
            revert NoTokenIdsGiven();
        }

        uint256 amountToIncrease = msg.value / _ids.length;

        for (uint256 i = 0; i < _ids.length; ++i) {
            uint256 tokenId = _ids[i];

            if (!_tokenExists(tokenId)) {
                revert TokenDoesNotExist();
            }

            tokenCredits[tokenId].totalCredit += amountToIncrease;
        }
    }

    /**
     * @dev Use this to increase every single cards' credit equally.
     * The `additionalCreditPerCard` value is added to the cards
     * total credit in all credit calculations.
     */
    function increaseAllCredit()
        external
        payable
        onlyRole(CREDIT_INCREASOR_ROLE)
        amountGreaterThanZero(msg.value)
    {
        additionalCreditPerCard += msg.value / MAX_SUPPLY;
    }

    /* =========== ADMIN FUNCTIONS =========== */

    /**
     * @dev Allows us to fund this contract to ensure there is 
     * enough initial credit available during minting. 
     * Funded amount is tracked and can be withdrawn later
     * using `withdrawPrefunds()`
     */
    function fund() external payable onlyOwner amountGreaterThanZero(msg.value) {
        fundedAmount += msg.value;
    }

    function toggleMinting(bool _value) external onlyOwner {
        mintActive = _value;
        emit MintingStatusUpdated(block.timestamp, _value);
    }

    function setBaseURI(string calldata _uri) external onlyOwner {
        baseURI = _uri;
    }

    /**
     * @dev Allows us to withdraw any funds sent using the `fund()` function.
     * Does not affect credit pool since these funds are tracked separately.
     */
    function withdrawPrefunds() external onlyOwner nonReentrant {
        if (fundedAmount == 0) {
            revert NothingToWithdraw();
        }
        if (fundedAmount > address(this).balance) {
            revert InsufficientContractBalance();
        }

        uint256 amount = fundedAmount;
        fundedAmount = 0;

        (bool success, ) = msg.sender.call{value: amount}("");
        if (!success) {
            revert WithdrawFailed();
        }
    }

    /**
     * @dev Allows us to withdraw left over funds that are not neccassary
     * for the credit claiming (aka our cut of the total mint value received).
     * @param _percentage The percentage of the available funds to withdraw. 
     *     Must be between 10 - 100
     */
    function withdrawPortion(uint256 _percentage) external onlyOwner nonReentrant {
        uint256 totalAmount = amountAvailableForOwnerWithdrawal(_percentage);
        if (totalAmount == 0) {
            revert NothingToWithdraw();
        }

        totalWithdrawedAmount += totalAmount;

        (bool success, ) = msg.sender.call{value: totalAmount}("");
        if (!success) {
            revert WithdrawFailed();
        }
    }

    /**
     * @dev Calculates the amount of funds available for owner withdrawal.
     * These funds are excess funds from the mint proceeds and does not
     * impact the credit claiminig abilities of token holders.
     * @param _percentage The percentage of the available funds to withdraw. 
     *     Must be between 10 - 100
     */
    function amountAvailableForOwnerWithdrawal(uint256 _percentage)
        public
        view
        onlyOwner
        returns (uint256)
    {
        if (_percentage < 9 || _percentage > 100) {
            revert WithdrawPercentageIncorrect();
        }

        uint256 totalCredit = mintCreditCounter - 1; // mintCreditCounter starts at 1
        uint256 totalAmount = MINT_PRICE * _totalMinted();

        if (totalCredit > totalAmount) {
            revert InsufficientContractBalance();
        }

        totalAmount -= totalWithdrawedAmount;
        totalAmount = ((totalAmount - totalCredit) * _percentage) / 100;

        if (totalAmount > address(this).balance) {
            revert InsufficientContractBalance();
        }

        return totalAmount;
    }

    /* =========== CHAINLINK CONFIG =========== */

    function setSubId(uint64 _subId) external onlyOwner {
        chainlinkConfig.subId = _subId;
    }

    function setCallbackGasLimit(uint32 _callbackGasLimit) external onlyOwner {
        chainlinkConfig.callbackGasLimit = _callbackGasLimit;
    }

    function setRequestConfirmations(uint16 _requestConfirmations) external onlyOwner {
        chainlinkConfig.requestConfirmations = _requestConfirmations;
    }

    function setKeyHash(bytes32 _keyHash) external onlyOwner {
        chainlinkConfig.keyHash = _keyHash;
    }

    /* =========== ERC165 =========== */

    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC2981Base, ERC721A, AccessControlEnumerable)
        returns (bool)
    {
        return
            ERC721A.supportsInterface(interfaceId) ||
            ERC2981Base.supportsInterface(interfaceId) ||
            AccessControlEnumerable.supportsInterface(interfaceId) ||
            super.supportsInterface(interfaceId);
    }

    /* =========== EIP-2981 ROYALTIES =========== */

    function setRoyalties(address _recipient, uint256 _value) external onlyOwner {
        _setRoyalties(_recipient, _value);
    }
}
