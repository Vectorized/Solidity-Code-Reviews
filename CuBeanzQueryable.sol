//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

error NotOwner();
error MaxTeamMints();
error RoundSoldOut();
error SaleNotStarted();
error InvalidValue();
error MaxMints();
error ContractMint();
/*

░█████╗░██╗░░░██╗██████╗░███████╗░█████╗░███╗░░██╗███████╗
██╔══██╗██║░░░██║██╔══██╗██╔════╝██╔══██╗████╗░██║╚════██║
██║░░╚═╝██║░░░██║██████╦╝█████╗░░███████║██╔██╗██║░░███╔═╝
██║░░██╗██║░░░██║██╔══██╗██╔══╝░░██╔══██║██║╚████║██╔══╝░░
╚█████╔╝╚██████╔╝██████╦╝███████╗██║░░██║██║░╚███║███████╗
░╚════╝░░╚═════╝░╚═════╝░╚══════╝╚═╝░░╚═╝╚═╝░░╚══╝╚══════╝

Dev: Shimazu Bohoro
*/


import "erc721a/contracts/extensions/ERC721AQueryable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";



contract CuBeanzQueryable is  ERC721AQueryable , Ownable, ReentrancyGuard {
    using Strings for uint256;
    using ECDSA for bytes32;

    //@dev mint constraints
    uint16 public teamMints;
    uint16 maxTeamMints = 444;
    uint16  roundOneSupply = 2222;
    uint16  roundTwoSupply = 1778;
    uint16 public roundOneMints;
    uint16 public roundTwoMints;

    uint8 maxRoundOneMints = 2;
    uint8 maxRoundTwoMints = 1;
    uint8 public maxAttacks  = 1;
    

    uint80 public burnRate = 10000 ether;
    uint80 public cubePrice = 22000 ether; 
    

    bool public roundOneLive;
    bool public roundTwoLive;

    bool burnMintActive;

    bool public revealed;   
    

    
    //@dev ryoToken obtained by burning cubes
    IERC20 public ryoToken; 


    


    //@dev tokenUri factory
    string public baseURI;
    string public notRevealedUri;
    string public uriSuffix = ".json";
    
   //@dev maps tokenIds to number of times they've attacked
   //@notice supply will never be > uint16 max value(65535) therefore we can reference to tokenIds by uint16
   //@notice numAttacks will never be more than 8 since maxAttacks will never be more than 8
    mapping(uint16 => uint8) public numAttacks;



    // @dev these mappings track how many one has minted on public and WL respectively
    mapping(address =>uint8) public rOneMapping;
    mapping(address => uint8) public rTwoMapping;

    constructor()
        ERC721A("CuBeanz", "CBZ")

    {
        // @dev make sure to keep baseUri as empty string to avoid your metadata being sniped
        setBaseURI("");
        setNotRevealedURI("ipfs://CID/hidden.json");
    }

    event ATTACK(uint indexed numAttack,uint indexed tokenId);
 
    function teamMint(address to ,uint8 amount) external onlyOwner  {
        if(teamMints + amount > maxTeamMints) revert MaxTeamMints();
        teamMints+= amount;
        _mint(to,amount);
    }
    function roundOneMint(uint8 amount) external  {
        
        if(!roundOneLive) revert SaleNotStarted();
        if(msg.sender != tx.origin) revert ContractMint();
        if(roundTwoLive) revert SaleNotStarted();
        if(roundOneMints + amount > roundOneSupply) revert RoundSoldOut();
        if(rOneMapping[msg.sender] + amount > maxRoundOneMints) revert MaxMints();
         rOneMapping[msg.sender]+=amount;
         roundOneMints += amount;
         _mint(msg.sender,amount);
    }

    function roundTwoMint(uint8 amount) external  {
        if(!roundTwoLive) revert SaleNotStarted();
        if(msg.sender != tx.origin) revert ContractMint();
        if(roundTwoMints + amount > roundTwoSupply) revert RoundSoldOut();
        if(rTwoMapping[msg.sender] + amount > maxRoundTwoMints) revert MaxMints();
        rTwoMapping[msg.sender] += amount;
        roundTwoMints += uint16(amount);
        _mint(msg.sender,amount);
    }


     function ryoMint(uint8 amount) external{
         if(!burnMintActive) revert SaleNotStarted();
         ryoToken.transferFrom(msg.sender,address(this), cubePrice * amount);
         _mint(msg.sender,amount);
     }

     function attackBean(uint16 tokenId) external{
        if(msg.sender != ownerOf(tokenId)) revert NotOwner();
         require(numAttacks[tokenId] < maxAttacks);
         numAttacks[tokenId]++;
         emit ATTACK(numAttacks[tokenId],tokenId);
     }


    function burnCube(uint16 tokenId) external {
        if(msg.sender != ownerOf(tokenId)) revert NotOwner();
        ryoToken.mint(msg.sender, burnRate);
        _burn(tokenId);
    }



    function burnBatchCubes(uint16[] calldata tokenIds) external{
        for(uint16 i; i<tokenIds.length;i++){
            if(msg.sender != ownerOf(tokenIds[i])) revert NotOwner();
            _burn(tokenIds[i]);
        }
        ryoToken.mint(msg.sender, burnRate * tokenIds.length);
    }


    //SETTERS
    function setMaxAttacks(uint8 amountAttacks) external onlyOwner {
        require(amountAttacks > maxAttacks);
        maxAttacks = amountAttacks;
    }

    function setRyoToken(address _address) external onlyOwner{
        ryoToken =  IERC20(_address);
    }

    function setRoundMaxSupply(uint8 roundNumber ,uint16 newSupply) external onlyOwner {
        if(roundNumber ==1){
            roundOneSupply = newSupply;
        }
        if(roundNumber == 2){
            roundTwoSupply = newSupply;
        }
    }

    function setRevealed(bool status) public onlyOwner {
        revealed = status;
    }

    function setNotRevealedURI(string memory _notRevealedURI) public onlyOwner {
        notRevealedUri = _notRevealedURI;
    }

    function setBaseURI(string memory _newBaseURI) public onlyOwner {
        baseURI = _newBaseURI;
    }

   
    function setUriSuffix(string memory _newSuffix) external onlyOwner{
        uriSuffix = _newSuffix;
    }

      function setSaleStarted(uint8 roundNumber, bool status) external onlyOwner{
        if(roundNumber == 1){
            roundOneLive = status;   
        }
        if(roundNumber == 2){
            roundTwoLive = status;
        }
        if(roundNumber == 3){
            burnMintActive = status;
        }
    }
 

    


    //END SETTERS

 


    // FACTORY

    function tokenURI(uint256 _tokenId)
        public
        view

        //ignore
        override(ERC721A)
        returns (string memory)
    {
        if (revealed == false) {
            return notRevealedUri;
        }

        string memory currentBaseURI = baseURI;
        return
            bytes(currentBaseURI).length > 0
                ? string(abi.encodePacked(currentBaseURI, _tokenId.toString(),uriSuffix))
                : "";
    }


  
    function withdrawryoToken() external onlyOwner{
        uint balance = ryoToken.balanceOf(address(this));
        ryoToken.transfer(owner(), balance);
    }

   
    


}

interface IERC20{

    function mint(address holder, uint tokenId) external;
    function balanceOf(address account) external view returns(uint);
    function transferFrom(address from, address to, uint amount) external;
    function transfer(address to, uint amount) external;
}
