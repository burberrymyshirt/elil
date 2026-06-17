#!/usr/bin/env elixir

Code.require_file "./utils.exs"

defmodule Elil.Logger do
  def error_log(msg), do: IO.puts msg
end

defmodule Evaluator do
  require Utils
  import Utils

  def parse(file, file_path) when is_pid(file) or is_atom(file) do
    # TODO: we just assume file is a valid atom or pid, so add validate_file or something
    contents = IO.read file, :eof
    lexer = Lexer.lex contents, file_path
    IO.inspect lexer
    todo()
  end
end

defmodule Lexer do
  require Utils
  import Utils
  alias Elil.Logger
  require Logger
  import Logger

  @enforce_keys [:file_path, :token, :value, :row, :col]
  defstruct [
    file_path: nil,
    token: nil,
    value: nil,
    row: -1,
    col: -1,
  ]

  defmodule Context do
    @enforce_keys [:file_path, :src_rest, :total_newlines, :chars_since_last_newline]
    defstruct [
      :file_path,
      :src_rest,
      :total_newlines,
      :chars_since_last_newline,
    ]
  end

  defmodule Token do
    def oparen(), do: :oparen
    def cparen(), do: :cparen
    def ident(), do: :ident
    def string(), do: :string
    def int(), do: :int
  end

  def lex(contents, file_path) do
    context = %Context{
      file_path: file_path,
      src_rest: contents,
      total_newlines: 0,
      chars_since_last_newline: 0,
    }
    do_lex(context, []);
  end

  defp do_lex(%Context{src_rest: rest} = _context, result) when rest === "", do: result

  defp do_lex(%Context{src_rest: <<char, rest::binary>>} = context, result) when char in [?\s, ?\t] do
    context_updates = [src_rest: rest, chars_since_last_newline: context.chars_since_last_newline + 1]
    do_lex struct!(context, context_updates), result
  end

  defp do_lex(%Context{src_rest: <<?\r, ?\n, rest::binary>>} = context, result) do
    context_updates = [
      src_rest: rest,
      chars_since_last_newline: 0,
      total_newlines: context.total_newlines + 1,
    ]
    do_lex struct!(context, context_updates), result
  end

  defp do_lex(%Context{src_rest: <<?\n, rest::binary>>} = context, result) do
    context_updates = [
      src_rest: rest,
      chars_since_last_newline: 0,
      total_newlines: context.total_newlines + 1,
    ]
    do_lex struct!(context, context_updates), result
  end

  #oparen
  defp do_lex(%Context{src_rest: <<?(, rest::binary>>} = context, result) do
    value = "("
    lexer = %__MODULE__{
      file_path: context.file_path,
      token: Token.oparen(),
      value: value,
      row: -1,
      col: -1,
    }
    context_updates = [src_rest: rest]
    do_lex struct!(context, context_updates), [lexer | result]
  end

  #cparen
  defp do_lex(%Context{src_rest: <<?), rest::binary>>} = context, result) do
    value = ")"
    lexer = %__MODULE__{
      file_path: context.file_path,
      token: Token.cparen(),
      value: value,
      row: -1,
      col: -1,
    }
    context_updates = [src_rest: rest]
    do_lex struct!(context, context_updates), [lexer | result]
  end

  #int
  defp do_lex(%Context{src_rest: <<char, _rest::binary>>} = context, result) when is_numeric(char) do
    {value, rest} = parse_integer(context)
    lexer = %__MODULE__{
      file_path: context.file_path,
      token: Token.int(),
      value: value,
      row: -1,
      col: -1,
    }
    context_updates = [src_rest: rest]
    do_lex struct!(context, context_updates), [lexer | result]
  end

  #dqstring
  defp do_lex(%Context{src_rest: <<?", rest::binary>>} = context, result) do
    # TODO: handle escaping and such

    charlist = String.to_charlist(rest)
    nl_index = Enum.find_index(charlist, fn c -> c === ?\n end)
    dq_index = (Enum.find_index charlist, (fn c -> c === ?" end))
    if is_nil(dq_index) do
      error_log "invalid string found" # make this make sense <:-}
      exit {:shutdown, 1}
    end
    if nl_index < dq_index do
      # TODO: if we do decide to use multiline strings, we need to handle newlines as well
      todo "multiline strings are not implemented yet"
      exit {:shutdown, 1}
    end

    {value, rest} = String.split_at(rest, dq_index)
    lexer = %__MODULE__{
      file_path: context.file_path,
      token: Token.string(),
      value: value,
      row: -1,
      col: -1,
    }
    <<_, rest::binary>> = rest # remove final double quote
    rest = chop_right(rest)
    context_updates = [src_rest: rest]
    do_lex struct!(context, context_updates), [lexer | result]
  end

  #identifier base case
  defp do_lex(%Context{} = context, result) do
    {value, rest} = parse_identifier(context)
    lexer = %__MODULE__{
      file_path: context.file_path,
      token: Token.ident(),
      value: value,
      row: -1,
      col: -1,
    }
    context_updates = [src_rest: rest]
    do_lex struct!(context, context_updates), [lexer | result]
  end

  defp parse_identifier(context, result \\ [])

  defp parse_identifier(%Context{src_rest: rest}, result), do: parse_identifier(rest, result)

  defp parse_identifier(<<char, rest::binary>>, result)
    when char in ?A..?z
      when char in [?_, ?-, ??]
        when char in [?æ, ?ø, ?å, ?Æ, ?Ø, ?Å] do
    parse_identifier(rest, [char | result])
  end

  defp parse_identifier(rest, result) do
    Enum.reverse(result)
    |> List.to_string()
    |> then(fn (result) -> {result, rest} end)
  end

  defp parse_integer(context, result \\ [])

  defp parse_integer(%Context{src_rest: rest}, result), do: parse_integer(rest, result)

  defp parse_integer(<<char, rest::binary>>, result) when char in ?0..?9 do
    parse_integer(rest, [char | result])
  end

  defp parse_integer(rest, result) do
    Enum.reverse(result)
    |> List.to_string()
    |> then(fn (result) -> {result, rest} end)
  end

  defp chop_right(str) do
    #handle escaped sequences. E.g. newlines written in src are \\n whereas actual newlines are \n
    if String.starts_with?(str, "\\") do
      {_, rest} = String.split_at(str, 2)
      rest
    else
      {_, rest} = String.split_at(str, 1)
      rest
    end
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
