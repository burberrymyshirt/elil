defmodule Elil.Cmd do
  alias Elil.Evaluator, as: Evaluator
  alias Elil.Utils, as: Utils

  @internal_prefix "_elil_internal"

  def main(argv) when is_list(argv) do
    # TODO: add --help option to this using the expected options. e.g. MyOptionParser that builds on top of the built in one.
    # TODO: in the above MyOptionParser, we should probably bake the add to env shit, because I don't like looking at it here either. It should be *magic*.
    # TODO: add shorthand option aliases.
    # TODO: handle errors. Right now they are just ignored, because who cares, just read the source code.
    # debug is a no-op right now
    {parsed, argv, _errors} =
      OptionParser.parse(argv, strict: [print_ast: :boolean, debug: :boolean])

    :ok = handle_options(parsed)

    handle_input_files(argv)
  end

  defp handle_input_files(file_paths) when is_list(file_paths) do
    {file_path, argv_rest} = List.pop_at(file_paths, 0)

    cond do
      is_nil(file_path) ->
        # WANT: implement repl
        Utils.print_usage("No file provided")
        exit({:shutdown, 1})

      !File.exists?(file_path) ->
        Utils.print_usage("No such file or directory: #{file_path}")
        exit({:shutdown, 1})

      true ->
        case File.open(file_path, [:utf8, :read_ahead]) do
          {:error, reason} ->
            Utils.print_usage("Couldn't open file #{file_path}. Reason: #{to_string(reason)}")

          {:ok, fd} ->
            Evaluator.eval(fd, file_path)

            if length(argv_rest) > 0 do
              handle_input_files(argv_rest)
            end
        end
    end
  end

  defp handle_options(options) when is_list(options) and length(options) === 0 do
    :ok
  end

  defp handle_options(options) when is_list(options) and length(options) > 0 do
    # TODO: idk maybe make this an agent as to not pollute fututre env functions introduced in Elil. ¯\_(ツ)_/¯
    options
    |> Enum.map(fn {k, v} -> {Atom.to_string(k), v} end)
    |> Enum.map(fn {k, v} -> {@internal_prefix <> k, v} end)
    |> Enum.map(fn {k, v} -> {String.to_atom(k), v} end)
    |> System.put_env()
  end

  def get_option(key, default \\ nil) when is_binary(key) do
    System.get_env(@internal_prefix<>key, default)
  end

  def get_option_bool(key, default \\ nil) when is_binary(key) do
    case System.get_env(@internal_prefix<>key, default) do
      "true" -> true
      "false" -> false
      otherwise -> otherwise
    end
  end
end
