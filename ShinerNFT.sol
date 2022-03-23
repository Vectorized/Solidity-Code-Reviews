// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "erc721a/contracts/ERC721A.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

contract OwnableDelegateProxy {}
contract ProxyRegistry { mapping(address => OwnableDelegateProxy) public proxies; }

contract LocalTest is ERC721A, Ownable
{
	uint256 public constant MAX_SUPPLY = 11111;
	uint256 public constant MINT_PRICE = 0.069 ether;
	address internal constant _community = 0x36E92eF696ac7f7B7Cf7BA9EC0C7D42E6e65A8AD;
	string internal _baseTokenURI = 'https://fake.robocosmic.online/';
	address immutable proxyRegistryAddress;
	bytes32 public _merkleRoot;

	enum Status { Initial, Presale, Sale, SoldOut }
	Status public status = Status.Initial;

	event StatusChanged();

	constructor(
		bytes32 merkleRoot,
		address _proxyRegistryAddress
	) ERC721A("LocalTest", "LTS")
	{
		_merkleRoot = merkleRoot;
		proxyRegistryAddress = _proxyRegistryAddress;

		_mint(_community, 13, '', false); // Initial Mint
	}

	modifier onlyAccounts() { require(msg.sender == tx.origin, "NO_ALLOWED_ORIGIN"); _; }

	function mint(uint256 quantity)
		external
		payable
		onlyAccounts
	{
		require(status == Status.Sale, "SALE_CLOSED");
		require(quantity != 0, "INVALID_QUANTITY");
		require(quantity <= 8, "QUANTITY_EXCEEDS_MAX_PER_CALL");
		require(quantity * MINT_PRICE == msg.value, "WRONG_ETH_AMOUNT");
		require(totalSupply() + quantity <= MAX_SUPPLY, "MAX_SUPPLY_EXCEEDED");

		_mint(msg.sender, quantity, '', true);
	}

	function mintWhitelist(uint256 quantity, uint256 numReserved, bytes32[] calldata _merkleProof)
		external
		payable
		onlyAccounts
	{
		require(status == Status.Presale, "WHITELIST_DISABLED");
		require(
			MerkleProof.verify(
				_merkleProof,
				_merkleRoot,
				keccak256(abi.encodePacked(msg.sender, numReserved))
			),
			"NOT_WHITELISTED"
		);
		require(quantity * MINT_PRICE == msg.value, "WRONG_ETH_AMOUNT");
		require(_numberMinted(msg.sender) + quantity <= 8, "MAX_EXCEEDED");
		require(totalSupply() + quantity <= 2222 + 13, "MAX_WHITELIST_EXCEEDED");

		_mint(msg.sender, quantity, '', true);
	}

	function mintSpecific(address[] calldata _addresses)
		public
		onlyOwner
	{
		require(_addresses.length > 0, "NO_PROVIDED_ADDRESSES");
		require(_addresses.length + totalSupply() <= MAX_SUPPLY, "MAX_SUPPLY_EXCEEDED");

		for (uint i = 0; i < _addresses.length;)
		{
			_mint(_addresses[i], 1, '', false);
			unchecked { i++; }
		}
	}

	function setStatus(uint256 _newStatus)
		external
		onlyOwner
	{
		status = Status(_newStatus);
		emit StatusChanged();
	}

	function setMerkleRoot(bytes32 root)
		public
		onlyOwner
	{
		_merkleRoot = root;
	}

	function setBaseURI(string memory baseTokenURI)
		external
		onlyOwner
	{
		_baseTokenURI = baseTokenURI;
	}

	function _baseURI()
		internal
		override(ERC721A)
		view
		returns (string memory)
	{
		return _baseTokenURI;
	}

	function numberMinted(address _address)
		external
		view
		returns (uint256)
	{
		return _numberMinted(_address);
	}

	function tokensOfOwner(address owner)
		external
		view
		returns (uint256[] memory)
	{
		unchecked {
			uint256[] memory a = new uint256[](balanceOf(owner));
			uint256 end = _currentIndex;
			uint256 tokenIdsIdx;
			address currOwnershipAddr;

			for (uint256 i; i < end; i++)
			{
				TokenOwnership memory ownership = _ownerships[i];
				if (ownership.burned)
				{
					continue;
				}

				if (ownership.addr != address(0))
				{
					currOwnershipAddr = ownership.addr;
				}

				if (currOwnershipAddr == owner)
				{
					a[tokenIdsIdx++] = i;
				}
			}

			return a;
		}
	}

	function withdraw()
		external
		onlyOwner
	{
		uint256 balance = address(this).balance;
		require(balance > 0, "INSUFFICIENT_FUNDS");

		transfer(0x833d3c68250C4b5966870B884e13d83417Cc46D3, balance * 35 / 100);
		transfer(0xcAE0c5062CD44Cb96D7AFfC6Faf3418D09491b67, balance * 35 / 100);
		transfer(0xf93A9737C7419C8E0085F599E60ABd0d7Ada221a, balance * 20 / 100);
		transfer(_community, balance * 10 / 100);

		transfer(owner(), address(this).balance);
	}

	function transfer(address to, uint256 amount)
		private
	{
		(bool success, ) = to.call{value: amount}("");
		require(success, "Transfer failed.");
	}

	function isApprovedForAll(address owner, address operator)
		override
		public
		view
		returns (bool)
	{
		ProxyRegistry proxyRegistry = ProxyRegistry(proxyRegistryAddress);
		if (address(proxyRegistry.proxies(owner)) == operator)
		{
			return true;
		}

		return super.isApprovedForAll(owner, operator);
	}

	function _startTokenId()
		internal
		view
		virtual
		override(ERC721A)
		returns (uint256)
	{
		return 1;
	}
}
