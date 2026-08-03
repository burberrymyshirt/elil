defmodule Elil.Lexer do
  require Elil.Utils
  import Elil.Utils
  import Elil.Logger
  use GenServer

  @enforce_keys [:token, :value, :row, :col]
  defstruct [
    :token,
    :value,
    :row,
    :col
  ]

  defmodule Context do
    @enforce_keys [:src_rest, :total_newlines, :chars_since_last_newline]
    defstruct [
      :src_rest,
      :total_newlines,
      :chars_since_last_newline
    ]

    def current_column(%Context{chars_since_last_newline: col}), do: col + 1

    def current_row(%Context{total_newlines: nl}), do: nl + 1
  end

  defmodule Token do
    def eof(), do: :eof
    def oparen(), do: :oparen
    def cparen(), do: :cparen
    def ident(), do: :ident
    def dqstring(), do: :dqstring
    def int(), do: :int
  end

  defmodule LexerState do
    defstruct [:file_path, :context, :current_token]
  end

  def get_current_token(pid) when is_pid(pid) do
    GenServer.call(pid, {:get_current_token})
  end

  def shift_token(pid) when is_pid(pid) do
    GenServer.call(pid, {:shift_token, 1})
  end

  def shift_token(pid, amount) when is_pid(pid) and is_integer(amount) do
    GenServer.call(pid, {:shift_token, amount})
  end

  def get_file_path(pid) when is_pid(pid) do
    GenServer.call(pid, {:file_path})
  end

  def start_link(default) when is_binary(default) do
    GenServer.start_link(__MODULE__, default)
  end

  @impl true
  def init({file_path, contents}) when is_binary(file_path) and is_binary(contents) do
    context = %Context{
      src_rest: contents,
      total_newlines: 0,
      chars_since_last_newline: 0
    }

    {:ok, %LexerState{file_path: file_path, context: context, current_token: nil}}
  end

  # TODO: all of this shifting and get_current_token is a bit limiting.
  #  I would like a read-forward buffer that is saved in the state, so we
  #  can read multiple tokens without shifting. I feel like that would make
  #  the parser api much more usable, when creating "expect" functions or
  #  patterns, to better handle errors. In this case, shift would shift from
  #  the stack first, and then start pulling from the stream again once empty.
  @impl true
  def handle_call({:shift_token, amount}, _from, %LexerState{} = lexer_state)
      when is_integer(amount) do
    {:ok, %Context{} = context, %Elil.Lexer{} = lexer} = do_lex(lexer_state.context)
    {:reply, lexer, struct!(lexer_state, context: context, current_token: lexer)}
  end

  @impl true
  def handle_call({:get_current_token}, _from, %LexerState{} = lexer_state) do
    {:reply, lexer_state.current_token, lexer_state}
  end

  @impl true
  def handle_call({:file_path}, _from, %LexerState{file_path: file_path} = lexer_state) do
    {:reply, file_path, lexer_state}
  end

  @impl true
  def handle_cast(_request, state) do
    {:noreply, state}
  end

  defp do_lex(%Context{src_rest: rest} = context) when rest === "" do
    value = ""
    context_updates = []
    return_lex({Token.eof(), value}, context, context_updates)
  end

  defp do_lex(%Context{src_rest: <<char, rest::binary>>} = context) when char in [?\s, ?\t] do
    context_updates = [
      src_rest: rest,
      chars_since_last_newline: context.chars_since_last_newline + 1
    ]

    continue_lex(context, context_updates)
  end

  defp do_lex(%Context{src_rest: <<?\r, ?\n, rest::binary>>} = context) do
    context_updates = [
      src_rest: rest,
      chars_since_last_newline: 0,
      total_newlines: context.total_newlines + 1
    ]

    continue_lex(context, context_updates)
  end

  defp do_lex(%Context{src_rest: <<?\n, rest::binary>>} = context) do
    context_updates = [
      src_rest: rest,
      chars_since_last_newline: 0,
      total_newlines: context.total_newlines + 1
    ]

    continue_lex(context, context_updates)
  end

  # oparen
  defp do_lex(%Context{src_rest: <<?(, rest::binary>>} = context) do
    value = "("

    context_updates = [
      src_rest: rest,
      chars_since_last_newline: context.chars_since_last_newline + String.length(value)
    ]

    return_lex({Token.oparen(), value}, context, context_updates)
  end

  # cparen
  defp do_lex(%Context{src_rest: <<?), rest::binary>>} = context) do
    value = ")"

    context_updates = [
      src_rest: rest,
      chars_since_last_newline: context.chars_since_last_newline + String.length(value)
    ]

    return_lex({Token.cparen(), value}, context, context_updates)
  end

  # int
  defp do_lex(%Context{src_rest: <<char, _rest::binary>>} = context) when is_numeric(char) do
    {value, rest} = parse_integer(context)

    context_updates = [
      src_rest: rest,
      chars_since_last_newline: context.chars_since_last_newline + String.length(value)
    ]

    return_lex({Token.int(), value}, context, context_updates)
  end

  # dqstring
  defp do_lex(%Context{src_rest: <<?", rest::binary>>} = context) do
    # WANT: handle escaping and such

    charlist = String.to_charlist(rest)
    nl_index = Enum.find_index(charlist, &(&1 === ?\n))
    dq_index = Enum.find_index(charlist, &(&1 === ?"))

    if is_nil(dq_index) do
      # make this make sense <:-}
      error_log("invalid string found")
      exit({:shutdown, 1})
    end

    if nl_index < dq_index do
      # TODO: if we do decide to use multiline strings, we need to handle newlines as well
      todo("multiline strings are not implemented yet")
      exit({:shutdown, 1})
    end

    # TODO: refactor line to parse_dqstring or something, like integer and identifier
    {value, rest} = String.split_at(rest, dq_index)
    rest = chop_right(rest)
    # +2 for the surrounding quotes
    context_updates = [
      src_rest: rest,
      chars_since_last_newline: context.chars_since_last_newline + String.length(value) + 2
    ]

    return_lex({Token.dqstring(), value}, context, context_updates)
  end

  # identifier base case
  defp do_lex(%Context{} = context) do
    {value, rest} = parse_identifier(context)

    context_updates = [
      src_rest: rest,
      chars_since_last_newline: context.chars_since_last_newline + String.length(value)
    ]

    return_lex({Token.ident(), value}, context, context_updates)
  end

  defp continue_lex(%Context{} = context, context_updates) when is_list(context_updates) do
    do_lex(struct!(context, context_updates))
  end

  defp return_lex({token, value}, %Context{} = context, context_updates)
       when is_list(context_updates) and is_atom(token) do
    lexer = %__MODULE__{
      token: token,
      value: value,
      row: Context.current_row(context),
      col: Context.current_column(context)
    }

    {:ok, struct!(context, context_updates), lexer}
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
    result
    |> Enum.reverse()
    |> List.to_string()
    |> then(&{&1, rest})
  end

  defp parse_integer(context, result \\ [])

  defp parse_integer(%Context{src_rest: rest}, result), do: parse_integer(rest, result)

  defp parse_integer(<<char, rest::binary>>, result) when char in ?0..?9 do
    parse_integer(rest, [char | result])
  end

  defp parse_integer(rest, result) do
    result
    |> Enum.reverse()
    |> List.to_string()
    |> then(&{&1, rest})
  end

  defp chop_right(str) do
    # WANT: handle escaped sequences. E.g. newlines written in src are \\n whereas actual newlines are \n
    if String.starts_with?(str, "\\") do
      {_, rest} = String.split_at(str, 2)
      rest
    else
      {_, rest} = String.split_at(str, 1)
      rest
    end
  end
end
