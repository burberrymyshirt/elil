defmodule Elil.Cmd do
  alias Elil.Evaluator, as: Evaluator
  alias Elil.Utils, as: Utils

  def main(argv) when is_list(argv) do
    {file_path, argv_rest} = List.pop_at(argv, 0)

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
              main(argv_rest)
            end
        end
    end
  end
end
