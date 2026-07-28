defmodule Evaluator do
  require Utils
  import Utils

  def eval(file, file_path) when is_pid(file) or is_atom(file) do
    # WANT: we just assume file is a valid atom or pid, so add validate_file or something
    IO.read(file, :eof) |> eval(file_path)
  end

  def eval(file, file_path) when is_binary(file) do
    {:ok, lexer_pid} = GenServer.start_link(Lexer, {file_path, file}, [hibernate_after: 100])
    {:ok, results} = Parser.parse(lexer_pid)
    IO.write(:stdio, "results: ")
    dump(results);

    todo()
  end
end
