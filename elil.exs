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
    lexer = Lexer.lex file_path, contents
    IO.inspect lexer
    todo()
  end
end

defmodule Lexer do
  require Utils
  import Utils

  @enforce_keys [:file_path, :token, :value, :row, :col]
  defstruct [
    file_path: nil,
    token: nil,
    value: nil,
    row: -1,
    col: -1,
  ]

  defmodule Context do
    @enforce_keys [:file_path, :current_char, :src_rest, :total_newlines, :chars_since_last_newline]
    defstruct [
      :file_path,
      :current_char,
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

  def lex(file_path, contents) do
    {char, rest} = String.trim_leading(contents) |> String.split_at(1)
    rest = String.trim_leading(rest)
    context = %Context{
      file_path: file_path,
      current_char: char,
      src_rest: rest,
      total_newlines: 0,
      chars_since_last_newline: 0,
    }
    do_lex(context, []);
  end

  defp do_lex(%Context{src_rest: rest} = _context, result) when is_list(result) and rest === "", do: result

  #oparen
  defp do_lex(%Context{current_char: char} = context, result) when is_list(result) and char === "(" do
    value = "("
    lexer = %__MODULE__{
      file_path: context.file_path,
      token: Token.oparen(),
      value: value,
      row: -1,
      col: -1,
    }
    result = [lexer | result]
    {char, rest} = String.trim_leading(context.src_rest) |> String.split_at(1)
    context_updates = [current_char: char, src_rest: rest]
    do_lex struct!(context, context_updates), result
  end

  #cparen
  defp do_lex(%Context{current_char: char} = context, result) when is_list(result) and char === ")" do
    value = ")"
    lexer = %__MODULE__{
      file_path: context.file_path,
      token: Token.cparen(),
      value: value,
      row: -1,
      col: -1,
    }
    result = [lexer | result]
    {char, rest} = String.trim_leading(context.src_rest) |> String.split_at(1)
    context_updates = [current_char: char, src_rest: rest]
    do_lex struct!(context, context_updates), result
  end

  #int
  defp do_lex(%Context{current_char: char} = context, result) when is_list(result) and is_numeric(char) do
    value = context.current_char<>parse_integer(context.src_rest)
    lexer = %__MODULE__{
      file_path: context.file_path,
      token: Token.int(),
      value: value,
      row: -1,
      col: -1,
    }
    result = [lexer | result]
    {_, rest} = String.split_at(context.src_rest, String.length(value) - 1) # chop remaining numbers
    {char, rest} = String.trim_leading(rest) |> String.split_at(1)
    context_updates = [current_char: char, src_rest: rest]
    do_lex struct!(context, context_updates), result
  end

  #dqstring
  defp do_lex(%Context{current_char: char} = context, result) when is_list(result) and char === "\"" do
    # TODO: handle escaping and such

    charlist = String.to_charlist(context.src_rest)
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

    {value, rest} = String.split_at(context.src_rest, dq_index)
    lexer = %__MODULE__{
      file_path: context.file_path,
      token: Token.string(),
      value: value,
      row: -1,
      col: -1,
    }
    result = [lexer | result]
    {_, rest} = String.split_at(rest, 1) # remove final double quote
    {char, rest} = chop_right(rest)
    context_updates = [current_char: char, src_rest: rest]
    do_lex struct!(context, context_updates), result
  end

  #identifier base case
  defp do_lex(context, result) when is_list(result) do
    space_index = String.split(context.src_rest, "", trim: true)
      |> (Enum.find_index &is_whitespace/1)
    if is_nil(space_index) do
      error_log "invalid identifier found" # TODO: make this make sense <:-}
      exit {:shutdown, 1}
    end
    {value, rest} = String.split_at(context.src_rest, space_index)
    value = context.current_char<>value
    if (! String.match?(value, ~r/^[a-zA-Z0-9\_\-\?]+$/)) do
      error_log "invalid identifier found #{value}" # add char not allowed to error message and maybe the actual found identifier
      exit {:shutdown, 1}
    end
    lexer = %__MODULE__{
      file_path: context.file_path,
      token: Token.ident(),
      value: value,
      row: -1,
      col: -1,
    }
    result = [lexer | result]
    {char, rest} = String.trim_leading(rest) |> String.split_at(1)
    context_updates = [current_char: char, src_rest: rest]
    do_lex struct!(context, context_updates), result
  end

  defp parse_integer(rest), do: do_parse_integer(rest, "")

  defp do_parse_integer(rest, result) do
    {char, rest} = String.split_at(rest, 1)
    case char do
      char when is_numeric(char) -> do_parse_integer rest, result<>char
      _ -> result
    end
  end

  defp chop_right(str) do
    #handle escaped sequences. E.g. newlines written in src are \\n whereas actual newlines are \n
    if String.starts_with?(str, "\\") do
      String.split_at(str, 2)
    else
      String.split_at(str, 1)
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
