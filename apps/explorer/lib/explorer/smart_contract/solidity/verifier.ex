# credo:disable-for-this-file
defmodule Explorer.SmartContract.Solidity.Verifier do
  @moduledoc """
  Module responsible to verify the Smart Contract.

  Given a contract source code the bytecode will be generated  and matched
  against the existing Creation Address Bytecode, if it matches the contract is
  then Verified.
  """

  alias ABI.{FunctionSelector, TypeDecoder}
  alias Explorer.Chain
  alias Explorer.SmartContract.Solidity.CodeCompiler

  require Logger

  @bytecode_hash_options ["default", "none", "bzzr1"]

  def evaluate_authenticity(_, %{"name" => ""}), do: {:error, :name}

  def evaluate_authenticity(_, %{"contract_source_code" => ""}),
    do: {:error, :contract_source_code}

  def evaluate_authenticity(address_hash, params) do
    try do
      latest_evm_version = List.last(CodeCompiler.allowed_evm_versions())
      evm_version = Map.get(params, "evm_version", latest_evm_version)

      all_versions = [evm_version | previous_evm_versions(evm_version)]

      all_versions_extra = all_versions ++ [evm_version]

      Enum.reduce_while(all_versions_extra, false, fn version, acc ->
        case acc do
          {:ok, _} = result ->
            {:cont, result}

          {:error, error}
          when error in [:name, :no_creation_data, :deployed_bytecode, :compiler_version, :constructor_arguments] ->
            {:halt, acc}

          _ ->
            cur_params = Map.put(params, "evm_version", version)
            {:cont, verify(address_hash, cur_params)}
        end
      end)
    rescue
      exception ->
        Logger.error(fn ->
          [
            "Error while verifying smart-contract address: #{address_hash}, params: #{inspect(params, limit: :infinity, printable_limit: :infinity)}: ",
            Exception.format(:error, exception)
          ]
        end)
    end
  end

  def evaluate_authenticity_via_standard_json_input(address_hash, params, json_input) do
    try do
      verify(address_hash, params, json_input)
    rescue
      exception ->
        Logger.error(fn ->
          [
            "Error while verifying smart-contract address: #{address_hash}, params: #{inspect(params, limit: :infinity, printable_limit: :infinity)}, json_input: #{inspect(json_input, limit: :infinity, printable_limit: :infinity)}: ",
            Exception.format(:error, exception)
          ]
        end)
    end
  end

  defp verify(address_hash, params, json_input) do
    name = Map.get(params, "name", "")
    compiler_version = Map.fetch!(params, "compiler_version")
    constructor_arguments = Map.get(params, "constructor_arguments", "")
    autodetect_constructor_arguments = params |> Map.get("autodetect_constructor_args", "false") |> parse_boolean()

    solc_output =
      CodeCompiler.run(
        [
          name: name,
          compiler_version: compiler_version
        ],
        json_input
      )

    case solc_output do
      {:ok, candidates} ->
        case Jason.decode(json_input) do
          {:ok, map_json_input} ->
            Enum.reduce_while(candidates, %{}, fn candidate, _acc ->
              file_path = candidate["file_path"]
              source_code = map_json_input["sources"][file_path]["content"]
              contract_name = candidate["name"]

              case compare_bytecodes(
                     candidate,
                     address_hash,
                     constructor_arguments,
                     autodetect_constructor_arguments
                   ) do
                {:ok, verified_data} ->
                  secondary_sources =
                    for {file, %{"content" => source}} <- map_json_input["sources"],
                        file != file_path,
                        do: %{"file_name" => file, "contract_source_code" => source, "address_hash" => address_hash}

                  additional_params =
                    map_json_input
                    |> extract_settings_from_json()
                    |> Map.put("contract_source_code", source_code)
                    |> Map.put("file_path", file_path)
                    |> Map.put("name", contract_name)
                    |> Map.put("secondary_sources", secondary_sources)

                  {:halt, {:ok, verified_data, additional_params}}

                err ->
                  {:cont, {:error, err}}
              end
            end)

          _ ->
            {:error, :json}
        end

      error_response ->
        error_response
    end
  end

  defp extract_settings_from_json(json_input) when is_map(json_input) do
    %{"enabled" => optimization, "runs" => optimization_runs} = json_input["settings"]["optimizer"]

    %{"optimization" => optimization}
    |> (&if(parse_boolean(optimization), do: Map.put(&1, "optimization_runs", optimization_runs), else: &1)).()
  end

  defp verify(address_hash, params) do
    name = Map.fetch!(params, "name")
    contract_source_code = Map.fetch!(params, "contract_source_code")
    optimization = Map.fetch!(params, "optimization")
    compiler_version = Map.fetch!(params, "compiler_version")
    external_libraries = Map.get(params, "external_libraries", %{})
    constructor_arguments = Map.get(params, "constructor_arguments", "")
    evm_version = Map.get(params, "evm_version")
    optimization_runs = Map.get(params, "optimization_runs", 200)
    autodetect_constructor_arguments = params |> Map.get("autodetect_constructor_args", "false") |> parse_boolean()

    if is_compiler_version_at_least_0_6_0?(compiler_version) do
      Enum.reduce_while(@bytecode_hash_options, false, fn option, acc ->
        case acc do
          {:ok, _} = result ->
            {:halt, result}

          {:error, error}
          when error in [:name, :no_creation_data, :deployed_bytecode, :compiler_version, :constructor_arguments] ->
            {:halt, acc}

          _ ->
            solc_output =
              CodeCompiler.run(
                name: name,
                compiler_version: compiler_version,
                code: contract_source_code,
                optimize: optimization,
                optimization_runs: optimization_runs,
                evm_version: evm_version,
                external_libs: external_libraries,
                bytecode_hash: option
              )

            {:cont,
             compare_bytecodes(
               solc_output,
               address_hash,
               constructor_arguments,
               autodetect_constructor_arguments
             )}
        end
      end)
    else
      solc_output =
        CodeCompiler.run(
          name: name,
          compiler_version: compiler_version,
          code: contract_source_code,
          optimize: optimization,
          optimization_runs: optimization_runs,
          evm_version: evm_version,
          external_libs: external_libraries
        )

      compare_bytecodes(
        solc_output,
        address_hash,
        constructor_arguments,
        autodetect_constructor_arguments
      )
    end
  end

  defp is_compiler_version_at_least_0_6_0?("latest"), do: true

  defp is_compiler_version_at_least_0_6_0?(compiler_version) do
    [version, _] = compiler_version |> String.split("+", parts: 2)

    digits =
      version
      |> String.replace("v", "")
      |> String.split(".")
      |> Enum.map(fn str ->
        {num, _} = Integer.parse(str)
        num
      end)

    Enum.fetch!(digits, 0) > 0 || Enum.fetch!(digits, 1) >= 6
  end

  defp compare_bytecodes({:error, :name}, _, _, _), do: {:error, :name}
  defp compare_bytecodes({:error, _}, _, _, _), do: {:error, :compilation}

  defp compare_bytecodes({:error, _, error_message}, _, _, _) do
    {:error, :compilation, error_message}
  end

  defp compare_bytecodes(
         %{"abi" => abi, "bytecode" => bytecode, "deployedBytecode" => deployed_bytecode},
         address_hash,
         arguments_data,
         autodetect_constructor_arguments
       ),
       do:
         compare_bytecodes(
           {:ok, %{"abi" => abi, "bytecode" => bytecode, "deployedBytecode" => deployed_bytecode}},
           address_hash,
           arguments_data,
           autodetect_constructor_arguments
         )

  defp compare_bytecodes(
         {:ok, %{"abi" => abi, "bytecode" => bytecode, "deployedBytecode" => deployed_bytecode}},
         address_hash,
         arguments_data,
         autodetect_constructor_arguments
       ) do
    %{
      "metadata_hash_with_length" => local_meta,
      "trimmed_bytecode" => local_bytecode_without_meta,
      "compiler_version" => solc_local
    } = extract_bytecode_and_metadata_hash(bytecode, deployed_bytecode)

    bc_deployed_bytecode = Chain.smart_contract_bytecode(address_hash)

    bc_creation_tx_input =
      case Chain.smart_contract_creation_tx_bytecode(address_hash) do
        %{init: init, created_contract_code: _created_contract_code} ->
          "0x" <> init_without_0x = init
          init_without_0x

        _ ->
          ""
      end

    %{
      "metadata_hash_with_length" => bc_meta,
      "trimmed_bytecode" => bc_creation_tx_input_without_meta,
      "compiler_version" => solc_bc
    } = extract_bytecode_and_metadata_hash(bc_creation_tx_input, bc_deployed_bytecode)

    bc_replaced_local =
      String.replace(bc_creation_tx_input_without_meta, local_bytecode_without_meta, "", global: false)

    has_constructor_with_params? = has_constructor_with_params?(abi)

    is_constructor_args_valid? =
      if has_constructor_with_params?, do: parse_constructor_and_return_check_function(abi), else: fn _ -> false end

    empty_constructor_arguments = arguments_data == "" or arguments_data == nil

    cond do
      bc_creation_tx_input == "" ->
        {:error, :no_creation_data}

      !String.contains?(bc_creation_tx_input, bc_meta) || bc_deployed_bytecode in ["", "0x"] ->
        {:error, :deployed_bytecode}

      bc_replaced_local == "" && !has_constructor_with_params? ->
        {:ok, %{abi: abi}}

      bc_replaced_local != "" && has_constructor_with_params? && is_constructor_args_valid?.(bc_replaced_local) &&
          autodetect_constructor_arguments ->
        {:ok, %{abi: abi, constructor_arguments: bc_replaced_local}}

      has_constructor_with_params? && autodetect_constructor_arguments &&
          ((bc_replaced_local != "" && !is_constructor_args_valid?.(bc_replaced_local)) || bc_replaced_local == "") ->
        {:error, :autodetect_constructor_arguments_failed}

      has_constructor_with_params? &&
          (empty_constructor_arguments || !String.contains?(bc_creation_tx_input, arguments_data)) ->
        {:error, :constructor_arguments}

      has_constructor_with_params? && is_constructor_args_valid?.(arguments_data) &&
          (bc_replaced_local == arguments_data ||
             check_users_constructor_args_validity(bc_creation_tx_input, bytecode, bc_meta, local_meta, arguments_data)) ->
        {:ok, %{abi: abi, constructor_arguments: arguments_data}}

      try_library_verification(local_bytecode_without_meta, bc_creation_tx_input_without_meta) ->
        {:ok, %{abi: abi}}

      true ->
        {:error, :unknown_error}
    end
  end

  defp check_users_constructor_args_validity(bc_bytecode, local_bytecode, bc_splitter, local_splitter, user_arguments) do
    clear_bc_bytecode = bc_bytecode |> replace_last_occurence(user_arguments) |> replace_last_occurence(bc_splitter)
    clear_local_bytecode = replace_last_occurence(local_bytecode, local_splitter)
    clear_bc_bytecode == clear_local_bytecode
  end

  defp replace_last_occurence(where, what) when is_binary(where) and is_binary(what) do
    where
    |> String.reverse()
    |> String.replace(String.reverse(what), "", global: false)
    |> String.reverse()
  end

  defp replace_last_occurence(_, _), do: nil

  defp parse_constructor_and_return_check_function(abi) do
    constructor_abi = Enum.find(abi, fn el -> el["type"] == "constructor" && el["inputs"] != [] end)

    input_types = Enum.map(constructor_abi["inputs"], &FunctionSelector.parse_specification_type/1)

    fn assumed_arguments ->
      try do
        _ =
          assumed_arguments
          |> Base.decode16!(case: :mixed)
          |> TypeDecoder.decode_raw(input_types)

        assumed_arguments
      rescue
        _ ->
          false
      end
    end
  end

  defp extract_meta_from_deployed_bytecode(code_unknown_case) do
    with true <- is_binary(code_unknown_case),
         code <- String.downcase(code_unknown_case),
         last_2_bytes <- code |> String.slice(-4..-1),
         {meta_length, ""} <- last_2_bytes |> Integer.parse(16),
         meta <- String.slice(code, (-(meta_length + 2) * 2)..-5) do
      {meta, last_2_bytes}
    else
      _ ->
        {"", ""}
    end
  end

  defp decode_meta(meta) do
    with {:ok, meta_raw_binary} <- Base.decode16(meta, case: :lower),
         {:ok, decoded_meta, _remain} <- CBOR.decode(meta_raw_binary) do
      decoded_meta
    else
      _ ->
        %{}
    end
  end

  # 730000000000000000000000000000000000000000 - default library address that returned by the compiler
  defp try_library_verification(
         "730000000000000000000000000000000000000000" <> bytecode,
         <<_address::binary-size(42)>> <> bytecode
       ) do
    true
  end

  defp try_library_verification(_, _) do
    false
  end

  @doc """
  In order to discover the bytecode we need to remove the `swarm source` from
  the hash.

  For more information on the swarm hash, check out:
  https://solidity.readthedocs.io/en/v0.5.3/metadata.html#encoding-of-the-metadata-hash-in-the-bytecode
  """
  def extract_bytecode_and_metadata_hash("0x" <> bytecode, deployed_bytecode) do
    extract_bytecode_and_metadata_hash(bytecode, deployed_bytecode)
  end

  def extract_bytecode_and_metadata_hash(bytecode, deployed_bytecode) do
    {meta, meta_length} = extract_meta_from_deployed_bytecode(deployed_bytecode)

    solc = decode_meta(meta)["solc"]

    bytecode_without_meta =
      bytecode
      |> replace_last_occurence(meta <> meta_length)

    %{
      "metadata_hash_with_length" => meta <> meta_length,
      "trimmed_bytecode" => bytecode_without_meta,
      "compiler_version" => solc
    }
  end

  def previous_evm_versions(current_evm_version) do
    index = Enum.find_index(CodeCompiler.allowed_evm_versions(), fn el -> el == current_evm_version end)

    cond do
      index == 0 ->
        []

      index == 1 ->
        [List.first(CodeCompiler.allowed_evm_versions())]

      true ->
        [
          Enum.at(CodeCompiler.allowed_evm_versions(), index - 1),
          Enum.at(CodeCompiler.allowed_evm_versions(), index - 2)
        ]
    end
  end

  defp has_constructor_with_params?(abi) do
    Enum.any?(abi, fn el -> el["type"] == "constructor" && el["inputs"] != [] end)
  end

  defp parse_boolean("true"), do: true
  defp parse_boolean("false"), do: false

  defp parse_boolean(true), do: true
  defp parse_boolean(false), do: false
end
