#!/usr/bin/env elixir

Code.require_file "./utils.exs"

defmodule Cmd do
  @default_message "Usage: elixir elil.exs [input_file]"

  def print_usage(message) when is_binary(message), do: print_usage [message]

  def print_usage(message) when is_list(message) do
    List.pop_at(message, 0)
      |> print_usage()
  end

  def print_usage({message, _rest})
    when is_list(message) and length(message) == 0
    when is_nil(message) do
    IO.puts @default_message
  end

  def print_usage({message, rest}) when is_binary(message) do
    IO.puts message
    print_usage rest
  end
end

defmodule Parser do
  require Utils
  import Utils

  defstruct row: nil, col: nil

  def parse(file) when is_pid(file) or is_atom(file) do
    # TODO: we just assume file is a valid atom or pid, so add validate_file or something
    todo()
  end
end
{file_path, _argv_rest} = List.pop_at(System.argv, 0);
cond do
  is_nil(file_path) ->
    # TODO: implement repl
    Cmd.print_usage "No file provided"
    exit {:shutdown, 1}

  ! File.exists?(file_path) ->
    Cmd.print_usage "No such file or directory: "<>file_path
    exit {:shutdown, 1}

  true ->
    case (File.open file_path, [:utf8, :read_ahead]) do
      {:error, reason} ->
        Cmd.print_usage "Couldn't open file "<>file_path<>". Reason: "<>to_string(reason)
      {:ok, fd} ->
        Parser.parse(fd)
    end
end
