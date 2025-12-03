defmodule EthereumJSONRPC.NFT do
  @moduledoc """
    Module responsible for requesting token_uri and uri methods which needed for NFT metadata fetching
  """

  @token_uri "c87b56dd"
  @base_uri "6c0360eb"
  @uri "0e89341c"
  # getData(bytes32) for LSP8
  @get_data "54f6127f"
  # getDataForTokenId(bytes32 tokenId, bytes32 dataKey) for LSP8 per-token metadata
  @get_data_for_token_id "16e023b3"

  @vm_execution_error "VM execution error"

  # LSP8TokenMetadataBaseURI: keccak256('LSP8TokenMetadataBaseURI')
  @lsp8_token_metadata_base_uri_key "0x1a7628600c3bac7101f53697f48df381ddc36b9015e7d7c9c5633d1252aa2843"

  # LSP8TokenIdFormat: keccak256('LSP8TokenIdFormat')
  # Describes how to interpret the bytes32 tokenId:
  # 0 = uint256 (number, left-padded)
  # 1 = string (UTF-8, right-padded, max 32 chars)
  # 2 = address (left-padded)
  # 3 = bytes32 (unique identifier, right-padded)
  # 4 = bytes32 (hash digest, no padding)
  @lsp8_token_id_format_key "0xf675e9361af1c1664c1868cfa3eb97672d6b1a513aa5b81dec34c9ee330e818d"

  # LSP4Metadata: keccak256('LSP4Metadata')
  # Used with getDataForTokenId to fetch per-token metadata
  @lsp4_metadata_key "0x9afb95cacc9f95858ec44aa8c3b685511002e30ae54415823f406128b85b238e"

  @erc_721_1155_abi [
    %{
      "inputs" => [],
      "name" => "baseURI",
      "outputs" => [
        %{
          "internalType" => "string",
          "name" => "",
          "type" => "string"
        }
      ],
      "stateMutability" => "view",
      "type" => "function"
    },
    %{
      "type" => "function",
      "stateMutability" => "view",
      "payable" => false,
      "outputs" => [
        %{"type" => "string", "name" => ""}
      ],
      "name" => "tokenURI",
      "inputs" => [
        %{
          "type" => "uint256",
          "name" => "_tokenId"
        }
      ],
      "constant" => true
    },
    %{
      "type" => "function",
      "stateMutability" => "view",
      "payable" => false,
      "outputs" => [
        %{
          "type" => "string",
          "name" => "",
          "internalType" => "string"
        }
      ],
      "name" => "uri",
      "inputs" => [
        %{
          "type" => "uint256",
          "name" => "_id",
          "internalType" => "uint256"
        }
      ],
      "constant" => true
    },
    %{
      "inputs" => [
        %{
          "internalType" => "bytes32",
          "name" => "dataKey",
          "type" => "bytes32"
        }
      ],
      "name" => "getData",
      "outputs" => [
        %{
          "internalType" => "bytes",
          "name" => "dataValue",
          "type" => "bytes"
        }
      ],
      "stateMutability" => "view",
      "type" => "function"
    },
    %{
      "inputs" => [
        %{
          "internalType" => "bytes32",
          "name" => "tokenId",
          "type" => "bytes32"
        },
        %{
          "internalType" => "bytes32",
          "name" => "dataKey",
          "type" => "bytes32"
        }
      ],
      "name" => "getDataForTokenId",
      "outputs" => [
        %{
          "internalType" => "bytes",
          "name" => "dataValue",
          "type" => "bytes"
        }
      ],
      "stateMutability" => "view",
      "type" => "function"
    }
  ]

  @doc """
    Executes batch requests to fetch metadata URLs for token instances.
    It first attempts to fetch using the primary method (tokenURI/uri). For failed requests,
    it may retry using baseURI based on application configuration.

    ## Parameters

    - `token_instances`: List of tuples containing {contract_address_hash, token_id, token_type}
    - `json_rpc_named_arguments`: Arguments for JSON RPC calls

    ## Returns

    - List of results with metadata URLs or errors
  """
  @spec batch_metadata_url_request(
          list({Explorer.Chain.Hash.Address.t(), non_neg_integer() | Decimal.t(), String.t()}),
          EthereumJSONRPC.json_rpc_named_arguments()
        ) :: list({:ok, [String.t()]} | {{:error, [String.t()]}, boolean()})
  def batch_metadata_url_request(token_instances, json_rpc_named_arguments) do
    {mb_retry, other} =
      token_instances
      |> prepare_requests()
      |> EthereumJSONRPC.execute_contract_functions(@erc_721_1155_abi, json_rpc_named_arguments, false)
      |> process_results()
      |> Enum.with_index()
      |> Enum.split_with(fn
        {{{:error, @vm_execution_error}, _from_base_uri}, _ind} -> true
        _ -> false
      end)

    retry_result =
      if Application.get_env(:indexer, Indexer.Fetcher.TokenInstance.Helper)[:base_uri_retry?] do
        {instances, indexes} =
          mb_retry
          |> Enum.map(fn {_, ind} ->
            {token_instances |> Enum.at(ind), ind}
          end)
          |> Enum.unzip()

        instances
        |> prepare_requests(true)
        |> EthereumJSONRPC.execute_contract_functions(@erc_721_1155_abi, json_rpc_named_arguments, false)
        |> process_results(true)
        |> Enum.zip(indexes)
      else
        mb_retry
      end

    (other ++ retry_result) |> Enum.sort_by(fn {_, ind} -> ind end) |> Enum.map(&elem(&1, 0))
  end

  defp process_results(results, from_base_uri? \\ false) do
    results
    |> Enum.map(fn
      {:error, error} ->
        error = to_string(error)

        error =
          if error =~ "execution reverted" or error =~ @vm_execution_error do
            @vm_execution_error
          else
            error
          end

        {{:error, error}, from_base_uri?}

      other ->
        {other, from_base_uri?}
    end)
  end

  defp prepare_requests(token_instances, from_base_uri? \\ false) do
    token_instances
    |> Enum.map(fn {token_contract_address_hash, token_id, token_type} ->
      token_id = prepare_token_id(token_id)
      token_contract_address_hash_string = to_string(token_contract_address_hash)

      prepare_request(
        token_type,
        token_contract_address_hash_string,
        token_id,
        from_base_uri?
      )
    end)
  end

  @doc """
    Prepares a request map for fetching metadata URL.
    ## Parameters
    - `token_type`: Type of token (ERC-404, ERC-721, ERC-1155, LSP8)
    - `contract_address_hash_string`: String representation of the contract address
    - `token_id`: Token ID as integer
    - `from_base_uri?`: Boolean indicating if request is for base URI
    ## Returns
    - Map with request parameters
  """
  @spec prepare_request(String.t(), String.t(), non_neg_integer(), boolean()) :: map()
  def prepare_request(token_type, contract_address_hash_string, token_id, from_base_uri?)
      when token_type in ["ERC-404", "ERC-721"] do
    request = %{
      contract_address: contract_address_hash_string,
      block_number: nil
    }

    if from_base_uri? do
      request |> Map.put(:method_id, @base_uri) |> Map.put(:args, [])
    else
      request |> Map.put(:method_id, @token_uri) |> Map.put(:args, [token_id])
    end
  end

  def prepare_request("LSP8", contract_address_hash_string, _token_id, _from_base_uri?) do
    # LSP8 uses getData(LSP8TokenMetadataBaseURI) to get the base URI
    # The token_id will be appended by decode_lsp8_metadata_uri in helper.ex
    prepare_lsp8_request(contract_address_hash_string)
  end

  def prepare_request(_token_type, contract_address_hash_string, token_id, from_base_uri?) do
    request = %{
      contract_address: contract_address_hash_string,
      block_number: nil
    }

    if from_base_uri? do
      request |> Map.put(:method_id, @base_uri) |> Map.put(:args, [])
    else
      request |> Map.put(:method_id, @uri) |> Map.put(:args, [token_id])
    end
  end

  @doc """
  Prepares token id for request.
  """
  @spec prepare_token_id(any) :: any
  def prepare_token_id(%Decimal{} = token_id), do: Decimal.to_integer(token_id)
  def prepare_token_id(token_id), do: token_id

  @doc """
  Prepares request for LSP8 token metadata.
  LSP8 uses getData(bytes32) with LSP8TokenMetadataBaseURI key to fetch the base URI.
  The token ID will be appended by decode_lsp8_metadata_uri.

  ## Parameters
  - `contract_address_hash_string`: String representation of the contract address

  ## Returns
  - Map with request parameters for getData call
  """
  @spec prepare_lsp8_request(String.t()) :: map()
  def prepare_lsp8_request(contract_address_hash_string) do
    %{
      contract_address: contract_address_hash_string,
      block_number: nil,
      method_id: @get_data,
      args: [@lsp8_token_metadata_base_uri_key]
    }
  end

  @doc """
  Prepares request for LSP8 token ID format.
  LSP8TokenIdFormat describes how to interpret the bytes32 tokenId.

  ## Parameters
  - `contract_address_hash_string`: String representation of the contract address

  ## Returns
  - Map with request parameters for getData call
  """
  @spec prepare_lsp8_token_id_format_request(String.t()) :: map()
  def prepare_lsp8_token_id_format_request(contract_address_hash_string) do
    %{
      contract_address: contract_address_hash_string,
      block_number: nil,
      method_id: @get_data,
      args: [@lsp8_token_id_format_key]
    }
  end

  @doc """
  Fetches the LSP8TokenIdFormat for a contract.

  ## Parameters
  - `contract_address_hash`: The contract address
  - `json_rpc_named_arguments`: Arguments for JSON RPC calls

  ## Returns
  - `{:ok, format}` where format is an integer (0-4, or 100-104 for mixed)
  - `{:error, reason}` if failed
  """
  @spec fetch_lsp8_token_id_format(
          Explorer.Chain.Hash.Address.t() | String.t(),
          EthereumJSONRPC.json_rpc_named_arguments()
        ) ::
          {:ok, non_neg_integer()} | {:error, String.t()}
  def fetch_lsp8_token_id_format(contract_address_hash, json_rpc_named_arguments) do
    contract_address_hash_string = to_string(contract_address_hash)

    [prepare_lsp8_token_id_format_request(contract_address_hash_string)]
    |> EthereumJSONRPC.execute_contract_functions(@erc_721_1155_abi, json_rpc_named_arguments, false)
    |> case do
      [{:ok, [bytes_data]}] when is_binary(bytes_data) ->
        # The format is stored as uint256 in bytes
        format = :binary.decode_unsigned(bytes_data)
        {:ok, format}

      [{:error, error}] ->
        {:error, to_string(error)}

      _ ->
        # Default to format 0 (number) if not set
        {:ok, 0}
    end
  end

  @doc """
  Formats an LSP8 token ID according to the LSP8TokenIdFormat for use in metadata URIs.

  ## Token ID Format Types:
  - 0: uint256 (number) - left-padded bytes32, displayed as decimal number
  - 1: string - right-padded bytes32, displayed as UTF-8 string
  - 2: address - left-padded bytes32, displayed as lowercase hex address
  - 3: bytes32 (unique identifier) - right-padded, displayed as lowercase hex (no 0x prefix)
  - 4: bytes32 (hash digest) - full 32 bytes, displayed as lowercase hex (no 0x prefix)

  ## Parameters
  - `token_id`: The token ID as integer or Decimal
  - `format`: The LSP8TokenIdFormat value (0-4, or 100-104 for mixed)

  ## Returns
  - Formatted token ID string suitable for use in metadata URI
  """
  @spec format_lsp8_token_id(integer() | Decimal.t(), non_neg_integer()) :: String.t()
  def format_lsp8_token_id(token_id, format) do
    token_id_int = normalize_token_id(token_id)
    effective_format = normalize_format(format)
    format_token_id_by_type(token_id_int, effective_format)
  end

  defp normalize_token_id(%Decimal{} = token_id), do: Decimal.to_integer(token_id)
  defp normalize_token_id(int) when is_integer(int), do: int

  defp normalize_format(format) when format >= 100, do: format - 100
  defp normalize_format(format), do: format

  defp format_token_id_by_type(token_id_int, 0), do: to_string(token_id_int)

  defp format_token_id_by_type(token_id_int, 1) do
    bytes32 = to_bytes32(token_id_int)
    trimmed = String.trim_trailing(bytes32, <<0>>)
    format_as_string_or_hex(trimmed, bytes32)
  end

  defp format_token_id_by_type(token_id_int, 2) do
    bytes32 = to_bytes32(token_id_int)
    <<_::binary-size(12), address_bytes::binary-size(20)>> = bytes32
    "0x" <> Base.encode16(address_bytes, case: :lower)
  end

  defp format_token_id_by_type(token_id_int, 3) do
    bytes32 = to_bytes32(token_id_int)
    Base.encode16(bytes32, case: :lower)
  end

  defp format_token_id_by_type(token_id_int, 4) do
    bytes32 = to_bytes32(token_id_int)
    Base.encode16(bytes32, case: :lower)
  end

  defp format_token_id_by_type(token_id_int, _), do: to_string(token_id_int)

  defp format_as_string_or_hex(trimmed, bytes32) do
    case :unicode.characters_to_binary(trimmed, :utf8) do
      utf8_string when is_binary(utf8_string) ->
        URI.encode(utf8_string)

      _ ->
        Base.encode16(bytes32, case: :lower)
    end
  end

  # Convert integer to exactly 32 bytes (bytes32)
  # If the encoded integer is less than 32 bytes, left-pad with zeros
  # If the encoded integer is more than 32 bytes, take only the last 32 bytes
  defp to_bytes32(int) when is_integer(int) do
    bytes = :binary.encode_unsigned(int)
    byte_size = byte_size(bytes)

    cond do
      byte_size == 32 ->
        bytes

      byte_size < 32 ->
        # Left-pad with zeros
        padding_size = 32 - byte_size
        <<0::size(padding_size * 8), bytes::binary>>

      byte_size > 32 ->
        # Take only the last 32 bytes (truncate from left)
        skip_bytes = byte_size - 32
        <<_::binary-size(skip_bytes), last_32::binary-size(32)>> = bytes
        last_32
    end
  end

  @doc """
  Returns the LSP8TokenIdFormat ERC725 data key.
  """
  @spec lsp8_token_id_format_key() :: String.t()
  def lsp8_token_id_format_key, do: @lsp8_token_id_format_key

  @doc """
  Returns the LSP4Metadata ERC725 data key.
  """
  @spec lsp4_metadata_key() :: String.t()
  def lsp4_metadata_key, do: @lsp4_metadata_key

  @doc """
  Converts a token ID to bytes32 format for use in getDataForTokenId calls.

  ## Parameters
  - `token_id`: The token ID as integer or Decimal

  ## Returns
  - bytes32 hex string with 0x prefix
  """
  @spec token_id_to_bytes32(integer() | Decimal.t()) :: String.t()
  def token_id_to_bytes32(token_id) do
    token_id_int =
      case token_id do
        %Decimal{} -> Decimal.to_integer(token_id)
        int when is_integer(int) -> int
      end

    bytes32 = to_bytes32(token_id_int)
    "0x" <> Base.encode16(bytes32, case: :lower)
  end

  @doc """
  Prepares request for LSP8 per-token metadata using getDataForTokenId.
  This is used as a fallback when LSP8TokenMetadataBaseURI is not set.

  ## Parameters
  - `contract_address_hash_string`: String representation of the contract address
  - `token_id`: The token ID as integer or Decimal

  ## Returns
  - Map with request parameters for getDataForTokenId call
  """
  @spec prepare_lsp8_token_metadata_request(String.t(), integer() | Decimal.t()) :: map()
  def prepare_lsp8_token_metadata_request(contract_address_hash_string, token_id) do
    token_id_bytes32 = token_id_to_bytes32(token_id)

    %{
      contract_address: contract_address_hash_string,
      block_number: nil,
      method_id: @get_data_for_token_id,
      args: [token_id_bytes32, @lsp4_metadata_key]
    }
  end

  @doc """
  Fetches LSP8 per-token metadata using getDataForTokenId with LSP4Metadata key.
  This is used as a fallback when LSP8TokenMetadataBaseURI is not available.

  ## Parameters
  - `contract_address_hash`: The contract address
  - `token_id`: The token ID
  - `json_rpc_named_arguments`: Arguments for JSON RPC calls

  ## Returns
  - `{:ok, [metadata_bytes]}` with the raw metadata bytes
  - `{:error, reason}` if failed
  """
  @spec fetch_lsp8_token_metadata(
          Explorer.Chain.Hash.Address.t() | String.t(),
          integer() | Decimal.t(),
          EthereumJSONRPC.json_rpc_named_arguments()
        ) ::
          {:ok, [binary()]} | {:error, String.t()}
  def fetch_lsp8_token_metadata(contract_address_hash, token_id, json_rpc_named_arguments) do
    contract_address_hash_string = to_string(contract_address_hash)

    [prepare_lsp8_token_metadata_request(contract_address_hash_string, token_id)]
    |> EthereumJSONRPC.execute_contract_functions(@erc_721_1155_abi, json_rpc_named_arguments, false)
    |> case do
      [{:ok, [bytes_data]}] when is_binary(bytes_data) and byte_size(bytes_data) > 0 ->
        {:ok, [bytes_data]}

      [{:ok, [<<>>]}] ->
        {:error, "LSP4Metadata is empty for this token"}

      [{:ok, []}] ->
        {:error, "LSP4Metadata is empty for this token"}

      [{:error, error}] ->
        {:error, to_string(error)}

      _ ->
        {:error, "Failed to fetch LSP4Metadata for token"}
    end
  end

  @doc """
  Returns the ABI of uri, tokenURI, baseURI getters for ERC-721 and ERC-1155 tokens.
  """
  @spec erc_721_1155_abi() :: list(map())
  def erc_721_1155_abi do
    @erc_721_1155_abi
  end
end
