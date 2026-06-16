#!/usr/bin/env elixir

Code.require_file "./utils.exs"

defmodule Evaluator do
  require Utils
  import Utils

  def parse(file, file_path) when is_pid(file) or is_atom(file) do
    # TODO: we just assume file is a valid atom or pid, so add validate_file or something
    contents = IO.read file, :eof
    lexer = Lexer.lex file_path, contents
    IO.inspect lexer
    todo()
  end
end

defmodule Lexer do
  require Utils
  import Utils

  defstruct [
    file_path: nil,
    token: nil,
    value: nil,
    row: nil,
    col: nil,
  ]

  defmodule Token do
    def oparen(), do: :oparen
    def cparen(), do: :cparen
    def ident(), do: :ident
    def string(), do: :string
    def int(), do: :int
  end

  def lex(_file_path, _char, rest, result) when is_list(result) and rest === "", do: result

  #oparen
  def lex(file_path, char, rest, result) when is_list(result) and char === "(" do
    value = "("
    lexer = %__MODULE__{
      file_path: file_path,
      token: Token.oparen(),
      value: value,
      row: -1,
      col: -1,
    }
    result = [lexer | result]
    {char, rest} = String.trim_leading(rest) |> String.split_at(1)
    lex file_path, char, rest, result
  end

  #cparen
  def lex(file_path, char, rest, result) when is_list(result) and char === ")" do
    value = ")"
    lexer = %__MODULE__{
      file_path: file_path,
      token: Token.cparen(),
      value: value,
      row: -1,
      col: -1,
    }
    result = [lexer | result]
    {char, rest} = String.trim_leading(rest) |> String.split_at(1)
    lex file_path, char, rest, result
  end

  #int
  def lex(file_path, char, rest, result) when is_list(result) and is_numeric(char) do
    value = char<>parse_integer(rest)
    lexer = %__MODULE__{
      file_path: file_path,
      token: Token.int(),
      value: value,
      row: -1,
      col: -1,
    }
    dump "Rest0: " <>rest
    {_, rest} = String.split_at(rest, String.length(value) - 1) # chop remaining numbers
    dump "Rest1: " <>rest
    {char, rest} = String.trim_leading(rest) |> String.split_at(1)
    dump "Rest2: " <>rest
    lex file_path, char, rest, [lexer | result]
  end

  #dqstring
  def lex(file_path, char, rest, result) when is_list(result) and char === "\"" do
    # TODO: handle escaping and such

    charlist = String.to_charlist(rest)
    nl_index = Enum.find_index(charlist, fn c -> c === ?\n end)
    dq_index = (Enum.find_index charlist, (fn c -> c === ?" end))
    if is_nil(dq_index) do
      error_log "invalid string found" # make this make sense <:-}
      exit {:shutdown, 1}
    end
    if nl_index < dq_index do
      todo "multiline strings are not implemented yet"
      exit {:shutdown, 1}
    end

    {value, rest} = String.split_at(rest, dq_index)
    lexer = %__MODULE__{
      file_path: file_path,
      token: Token.string(),
      value: value,
    }
    result = [lexer | result]
    {_, rest} = String.split_at(rest, 1) # remove final double quote
    {char, rest} = chop_right(rest)
    lex file_path, char, rest, result
  end

  @doc """
  identifier base case
  """
  def lex(file_path, char, rest, result) when is_list(result) do
    space_index = String.split(rest, "", trim: true)
      |> (Enum.find_index &is_whitespace/1)
    if is_nil(space_index) do
      error_log "invalid identifier found" # TODO: make this make sense <:-}
      exit {:shutdown, 1}
    end
    {value, rest} = String.split_at(rest, space_index)
    value = char<>value
    if (! String.match?(value, ~r/^[a-zA-Z0-9\_\-\?]+$/)) do
      IO.inspect(result)
      error_log "invalid identifier found #{value}" # add char not allowed to error message and maybe the actual found identifier
      exit {:shutdown, 1}
    end
    token = parse_identifier_token(char, rest)
    lexer = %__MODULE__{
      file_path: file_path,
      token: token,
      value: value,
      row: -1,
      col: -1,
    }
    result = [lexer | result]
    {char, rest} = String.trim_leading(rest) |> String.split_at(1)
    lex file_path, char, rest, result
  end

  defp parse_identifier_token(_char, _rest) do
    Token.ident()
  end

  defp parse_integer(rest, result \\ "") do
    {char, rest} = String.split_at(rest, 1)
    case char do
      char when is_numeric(char) -> parse_integer rest, result<>char
      _ -> result
    end
  end

  defp chop_right(str) do
    if String.starts_with?(str, "\\") do
      String.split_at(str, 2)
    else
      String.split_at(str, 1)
    end
  end

  def lex(file_path, contents) do
    {char, rest} = String.split_at(contents, 1)
    rest = String.trim_leading(rest)
    lex(file_path, char, rest, []);
  end
end

{file_path, _argv_rest} = List.pop_at(System.argv, 0);
cond do
  is_nil(file_path) ->
    # TODO: implement repl
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
        Evaluator.parse(fd, file_path)
    end
end
