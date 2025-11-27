defmodule Indexer.Transform.AddressTokenBalances do
  @moduledoc """
  Extracts `Explorer.Address.TokenBalance` params from other schema's params.
  """

  import Explorer.Chain.SmartContract, only: [burn_address_hash_string: 0]

  def params_set(%{} = import_options) do
    Enum.reduce(import_options, MapSet.new(), &reducer/2)
  end

  defp reducer({:token_transfers_params, token_transfers_params}, initial) when is_list(token_transfers_params) do
    token_transfers_params
    |> Enum.reduce(initial, fn %{
                                 block_number: block_number,
                                 from_address_hash: from_address_hash,
                                 to_address_hash: to_address_hash,
                                 token_contract_address_hash: token_contract_address_hash,
                                 token_ids: token_ids,
                                 token: %{type: token_type}
                               } = transfer,
                               acc
                               when is_integer(block_number) and is_binary(from_address_hash) and
                                      is_binary(to_address_hash) and is_binary(token_contract_address_hash) ->
      sanitized_token_ids =
        if is_nil(token_ids) || (is_list(token_ids) && Enum.empty?(token_ids)), do: [nil], else: token_ids

      Enum.reduce(sanitized_token_ids, acc, fn id, sub_acc ->
        sub_acc
        |> add_token_balance_address(
          from_address_hash,
          token_contract_address_hash,
          id,
          token_type,
          block_number,
          transfer
        )
        |> add_token_balance_address(
          to_address_hash,
          token_contract_address_hash,
          id,
          token_type,
          block_number,
          transfer
        )
      end)
    end)
  end

  defp add_token_balance_address(map_set, unquote(burn_address_hash_string()), _, _, _, _, _), do: map_set

  defp add_token_balance_address(
         map_set,
         address,
         token_contract_address,
         token_id,
         token_type,
         block_number,
         transfer
       ) do
    MapSet.put(map_set, %{
      address_hash: address,
      token_contract_address_hash: token_contract_address,
      block_number: block_number,
      token_id: token_id,
      token_type: token_type,
      value: lsp8_value(token_type, address, transfer),
      value_fetched_at: lsp8_value_fetched_at(token_type)
    })
  end

  # For LSP8 tokens, set value based on transfer direction (1 for recipient, 0 for sender)
  defp lsp8_value("LSP8", address, %{to_address_hash: to_address_hash}) do
    if address == to_address_hash, do: Decimal.new(1), else: Decimal.new(0)
  end

  defp lsp8_value(_, _, _), do: nil

  # For LSP8 tokens, set value_fetched_at to mark as fetched
  defp lsp8_value_fetched_at("LSP8"), do: DateTime.utc_now()
  defp lsp8_value_fetched_at(_), do: nil
end
