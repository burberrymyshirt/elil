defmodule Elil.Logger do
  def error_log_and_die(msg) when is_binary(msg) do
    error_log(msg)
    exit({:shutdown, 1})
  end

  def error_log_and_die(file_path, msg) when is_binary(file_path) and is_binary(msg) do
    error_log(file_path, msg)
    exit({:shutdown, 1})
  end

  def error_log_and_die(file_path, %Elil.Lexer{} = lexer, msg)
      when is_binary(file_path) and is_binary(msg) do
    error_log_and_die(file_path, {lexer.row, lexer.col}, msg)
  end

  def error_log_and_die(file_path, {row, col} = pos, msg)
      when is_integer(row) and is_integer(col) and is_binary(file_path) and is_binary(msg) do
    error_log(file_path, pos, msg)
    exit({:shutdown, 1})
  end

  # TODO: @see logging errors in todo.txt
  #  proper error logging with codes and ascii escape code colors and such
  def error_log(msg) when is_binary(msg), do: IO.puts(msg)

  def error_log(file_path, msg) when is_binary(file_path) and is_binary(msg) do
    error_log("#{file_path} #{msg}")
  end

  def error_log(file_path, {row, col}, msg)
      when is_binary(file_path) and is_integer(row) and is_integer(col) and is_binary(msg) do
    error_log("#{file_path}:#{row}:#{col} #{msg}")
  end
end
