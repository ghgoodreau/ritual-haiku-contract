// SPDX-License-Identifier: MIT

// @@@@@@@   @@@  @@@@@@@  @@@  @@@   @@@@@@   @@@          @@@  @@@   @@@@@@   @@@  @@@  @@@  @@@  @@@  
// @@@@@@@@  @@@  @@@@@@@  @@@  @@@  @@@@@@@@  @@@          @@@  @@@  @@@@@@@@  @@@  @@@  @@@  @@@  @@@  
// @@!  @@@  @@!    @@!    @@!  @@@  @@!  @@@  @@!          @@!  @@@  @@!  @@@  @@!  @@!  !@@  @@!  @@@  
// !@!  @!@  !@!    !@!    !@!  @!@  !@!  @!@  !@!          !@!  @!@  !@!  @!@  !@!  !@!  @!!  !@!  @!@  
// @!@!!@!   !!@    @!!    @!@  !@!  @!@!@!@!  @!!          @!@!@!@!  @!@!@!@!  !!@  @!@@!@!   @!@  !@!  
// !!@!@!    !!!    !!!    !@!  !!!  !!!@!!!!  !!!          !!!@!!!!  !!!@!!!!  !!!  !!@!!!    !@!  !!!  
// !!: :!!   !!:    !!:    !!:  !!!  !!:  !!!  !!:          !!:  !!!  !!:  !!!  !!:  !!: :!!   !!:  !!!  
// :!:  !:!  :!:    :!:    :!:  !:!  :!:  !:!   :!:         :!:  !:!  :!:  !:!  :!:  :!:  !:!  :!:  !:!  
// ::   :::   ::     ::    ::::: ::  ::   :::   :: ::::     ::   :::  ::   :::   ::   ::  :::  ::::: ::  
//  :   : :  :       :      : :  :    :   : :  : :: : :      :   : :   :   : :  :     :   :::   : :  :
 
 // @author: Hunty (@ownsacomputer)
 // @dev: an experimental ERC721 contract that connects to a Ritual infernet node which uses LLM inference to mint tokens based on user input.
 // @buzzwords: AI ARTIFICIAL INTELLIGENCE NODE COMPUTE DECENTRALIZED MACHINE LEARNING

 // @notice: use retryCompute() function to retry in the case of a failed compute (NFT metadata not updating)
 // @security: unaudited and simple proof of concept, use at your own risk. Author not responsible for losses.

pragma solidity ^0.8.21;

import {CallbackConsumer} from "infernet-sdk/consumer/Callback.sol";

import "openzeppelin-contracts/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "openzeppelin-contracts/contracts/utils/Strings.sol";
import "openzeppelin-contracts/contracts/utils/Base64.sol";
import "openzeppelin-contracts/contracts/interfaces/IERC2981.sol";
import "openzeppelin-contracts/contracts/access/Ownable.sol";

contract RitualHaiku is CallbackConsumer, ERC721URIStorage, IERC2981, Ownable {
    // @dev: we use this to keep track of the current token ID throughout the contract.
    uint256 private _tokenCounter;
    // @dev: boolean to keep track of whether the contract is paused.
    // @dev: initialize to true so that the contract is paused on deployment.
    bool private _paused = true;

    // mint price: 0.00575 ether per haiku. 5-7-5. around $20 at deployment time
    uint256 public mintPrice = 0.00575 ether; 
    // @dev: we keep track of this to enable retrying in the case of a compute failure on the Ritual side.
    mapping (uint256 => bool) private _tokenComputeSuccessById;

    string public placeholderURI;
    
    constructor(
        address coordinator
    ) CallbackConsumer(coordinator) ERC721("Ritual Haikus", "RTHK") Ownable(msg.sender) {
        _tokenCounter = 1;
        placeholderURI = _createPlaceholderSVG();
        
    }

    //@function: mints a haiku nft and attempts to compute a haiku based on the input.
    //@params: input, which is the user's input for the haiku.
    //@notice: this function is experimental and may fail if the Ritual node is down or if the input is not valid.
    //@notice: also, LLMs are not always reliable - the output may not be a haiku in rare cases, in which case, you will need to retry.
    //@notice: in the case of failure (mint succeeds but metadata doesn't update), retry by calling retryCompute 
    //         with the tokenID and the same (or different) input.
    function mintHaiku(string memory input) public payable {
        require(!_paused, "Minting is not open.");
        require(_tokenCounter < 576, "Maximum of 575 tokens can be minted");
        require(msg.value >= mintPrice, "Insufficient payment - minting costs 0.00575 ether.");
        uint256 currTokenId = _tokenCounter;
        _mint(msg.sender, _tokenCounter);
        _setTokenURI(_tokenCounter, placeholderURI);
        _tokenCounter++;
        _requestCompute(
            "ritual-haiku-minter",
            bytes(abi.encode(currTokenId, input)), 
            150 gwei, 
            4_000_000,
            1 
        );
    }

    //@function: retries the compute for a given tokenID, since they are not guaranteed to succeed.
    //@params: idToRetry, which is the tokenID to retry the compute for. newInput is the new input to use for the compute.
    //@notice: if this fails, just call it again. this is experimental and Ritual is early - should not fail more than a few times.
    function retryCompute(uint256 idToRetry, string memory newInput) public {
    //@dev: the purpose of this function is to allow the user to retry the compute if it fails to complete.
    //@dev: because of this, some conditions need to be met: the tokenID exists, the token has not already been computed,
    //@dev: and the user owns the token.
    require(idToRetry < _tokenCounter, "Token does not exist");
    require(ownerOf(idToRetry) == msg.sender, "You do not own this token");
    require(!_tokenComputeSuccessById[idToRetry], "Compute already succeeded for this token");

    //@dev: if the above checks succeed, we can retry the compute for the given tokenID.
    _requestCompute(
        "ritual-haiku-minter",
        bytes(abi.encode(idToRetry, newInput)), 
        150 gwei, 
        4_000_000, 
        1
    );
}

    //@function: Ritual inference callback when compute is delivered.
    //@docs: https://docs.ritual.net/infernet/sdk/consumers/Callback
    function _receiveCompute(
        uint32 subscriptionId,
        uint32 interval,
        uint16 redundancy,
        address node,
        bytes calldata input,
        bytes calldata output,
        bytes calldata proof
    ) internal override {
        //@dev: Decode the output from the compute into an address and a string array, which represents a haiku.
        (bytes memory raw_output, bytes memory processed_output) = abi.decode(output, (bytes, bytes));
        (uint256 tokenIdToUpdate, string[] memory haiku) = abi.decode(raw_output, (uint256, string[]));
        //@dev: The tokenId must exist and the compute must not have already succeeded.
        require(tokenIdToUpdate < _tokenCounter, "Token does not exist.");
        require(!_tokenComputeSuccessById[tokenIdToUpdate], "Compute already succeeded for this token.");

        //@dev: creates the svg and sets the tokenURI to the svg.
        string memory svg = _createSVG(haiku, tokenIdToUpdate);
        _setTokenURI(tokenIdToUpdate, svg);

        //@dev: The compute is marked as successful for the token ID, locking it out of being retried.
        _tokenComputeSuccessById[tokenIdToUpdate] = true; 
    }

    //@dev private svg functions
    function _createSVG(
        string[] memory lines, uint256 tokenId
    ) private pure returns (string memory) {
        string[7] memory parts;
        parts[
            0
        ] = '<svg xmlns="http://www.w3.org/2000/svg" preserveAspectRatio="xMinYMin meet" viewBox="0 0 350 350"><style>.base { fill: #DAD1CA; font-family: inter; font-size: 14px; text-transform: lowercase; }</style><rect width="100%" height="100%" fill="#0c0e0e" /><text x="30" y="30" class="base">';
        parts[1] = lines[0];
        parts[2] = '</text><text x="30" y="60" class="base">';
        parts[3] = lines[1];
        parts[4] = '</text><text x="30" y="90" class="base">';
        parts[5] = lines[2];
        parts[
            6
        ] = '</text><text x="30" y="320" class="base" style="font-style:italic">ritual haiku</text></svg>';
        string memory output = string(abi.encodePacked(parts[0], parts[1], parts[2], parts[3], parts[4], parts[5], parts[6]));
        string memory json = Base64.encode(bytes(string(abi.encodePacked('{"name": "Ritual Haiku #', Strings.toString(tokenId), '", "description": "Invoke the power of AI with any text prompt and receive a unique NFT, a haiku, crafted from your inspiration. Ritual Haiku is a testament to the fusion of blockchain and artificial intelligence, powered by Ritual. Each token is a personalized piece of art, a poetic expression born from your imagination and brought to life through decentralized machine learning.", "image": "data:image/svg+xml;base64,', Base64.encode(bytes(output)), '"}'))));
        output = string(abi.encodePacked('data:application/json;base64,', json));
        return output;
    }

    function _createPlaceholderSVG() private pure returns (string memory) {
        string memory svg = string(abi.encodePacked(
            '<svg xmlns="http://www.w3.org/2000/svg" preserveAspectRatio="xMinYMin meet" viewBox="0 0 350 350">',
            '<style>.base{fill:#dad1ca;font-family:inter;font-size:14px;text-transform:lowercase}.warning{fill:red}</style>',
            '<rect width="100%" height="100%" fill="#0c0e0e"/>',
            '<text x="30" y="30" class="base">Compute not yet here, </text>',
            '<text x="30" y="60" class="base">Retry function, last resort,</text>',
            '<text x="30" y="90" class="base">Token&apos;s fate unclear.</text>',
            '<text x="30" y="150" class="base warning">please call retryCompute() on the contract</text>',
            '<text x="30" y="170" class="base warning">to retry ritual inference and haiku generation.</text>',
            '<text x="30" y="320" class="base" style="font-style:italic">ritual haiku</text></svg>'
        ));
        string memory json = Base64.encode(bytes(string(abi.encodePacked('{"name": "Pending Ritual Haiku", "description": "Invoke the power of AI with any text prompt and receive a unique NFT, a haiku, crafted from your inspiration. Ritual Haiku is a testament to the fusion of blockchain and artificial intelligence, powered by Ritual. Each token is a personalized piece of art, a poetic expression born from your imagination and brought to life through decentralized machine learning.", "image": "data:image/svg+xml;base64,', Base64.encode(bytes(svg)), '"}'))));
        string memory output = string(abi.encodePacked('data:application/json;base64,', json));
        return output;
    }

    function royaltyInfo(uint256 _tokenId, uint256 _salePrice) external view override returns (address receiver, uint256 royaltyAmount) {
        receiver = owner();
        royaltyAmount = (_salePrice * 5) / 100;
    }

    function withdraw() public onlyOwner {
        payable(owner()).transfer(address(this).balance);
    }

    function togglePause() public onlyOwner {
        _paused = !_paused;
    }

    //@dev: allows the owner to reset a token to be recomputed.
    //      this is useful if a user gets a weird LLM response and requests it to be recomputed
    function resetComputeSuccess(uint256 tokenId) public onlyOwner {
        require(tokenId < _tokenCounter, "Token does not exist");
        _setTokenURI(tokenId, placeholderURI);
        _tokenComputeSuccessById[tokenId] = false;
    }
}