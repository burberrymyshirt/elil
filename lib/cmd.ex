defmodule Cmd do
  def start(argv) when is_list(argv) do
    {file_path, _argv_rest} = List.pop_at(System.argv, 0);
    cond do
      is_nil(file_path) ->
        # WANT: implement repl
        Utils.print_usage "No file provided"
        exit {:shutdown, 1}

      ! File.exists?(file_path) ->
        Utils.print_usage "No such file or directory: #{file_path}"
        exit {:shutdown, 1}

      true ->
        case (File.open file_path, [:utf8, :read_ahead]) do
          {:error, reason} ->
            Utils.print_usage "Couldn't open file #{file_path}. Reason: #{to_string(reason)}"
          {:ok, fd} ->
            Evaluator.eval(fd, file_path)
        end
    end
  end
end
