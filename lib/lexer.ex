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
    @enforce_keys [:src_rest, :total_newlines, :chars_since_last_newline, :skip_comments]
    defstruct [
      :src_rest,
      :total_newlines,
      :chars_since_last_newline,
      :skip_comments
    ]

    def current_column(%Context{chars_since_last_newline: col}), do: col + 1

    def current_row(%Context{total_newlines: nl}), do: nl + 1
  end

  @keywords ["let", "fn"]

  defmodule Token do
    def eof(), do: :eof
    def oparen(), do: :oparen
    def cparen(), do: :cparen
    def ident(), do: :ident
    def dqstring(), do: :dqstring
    def int(), do: :int
    def cmt(), do: :cmt
    def kwd(), do: :kwd
  end

  defmodule LexerState do
    defstruct [:file_path, :context, :current_token]
  end

  def lex_entire_file(file) do
    case File.exists?(file) do
      true ->
        {:ok, fd} = File.open(file)
        contents = IO.read(fd, :eof)
        lex_entire_file(contents, file)

      false ->
        lex_entire_file(file, "eval()")
    end
  end

  def lex_entire_file(file, file_path) do
    {:ok, pid} = GenServer.start_link(__MODULE__, {file_path, file}, hibernate_after: 100)
    list = do_lex_entire_file(pid)
    GenServer.stop(pid)
    list
  end

  defp do_lex_entire_file(pid, result \\ []) when is_pid(pid) do
    case shift(pid) do
      %__MODULE__{token: :eof} -> Enum.reverse(result)
      %__MODULE__{} = l -> do_lex_entire_file(pid, [l | result])
    end
  end

  def current(pid) when is_pid(pid) do
    GenServer.call(pid, {:get_current_token})
  end

  def shift(pid, amount \\ 1) when is_pid(pid) do
    GenServer.call(pid, {:shift_token, amount})
  end

  def get_file_path(pid) when is_pid(pid) do
    GenServer.call(pid, {:file_path})
  end

  def start_link(default) when is_binary(default) do
    GenServer.start_link(__MODULE__, default)
  end

  def init({file_path, contents}) when is_binary(file_path) and is_binary(contents) do
    # Default to skipping comments = true
    init({file_path, contents, true})
  end

  @impl true
  def init({file_path, contents, skip_comments})
      when is_binary(file_path) and is_binary(contents) do
    context = %Context{
      src_rest: contents,
      total_newlines: 0,
      chars_since_last_newline: 0,
      skip_comments: skip_comments
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
  def handle_call({:file_path}, _from, %LexerState{} = lexer_state) do
    {:reply, lexer_state.file_path, lexer_state}
  end

  @impl true
  def handle_cast(_request, state) do
    {:noreply, state}
  end

  defguardp valid_identifier_char(char)
            when char in ?A..?z or
                   char in [?_, ?-, ??, ?æ, ?ø, ?å, ?Æ, ?Ø, ?Å]

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

  # cmt
  defp do_lex(%Context{src_rest: <<?;, rest::binary>>} = context) do
    {value, rest} = parse_comment(rest)

    context_updates = [
      src_rest: rest,
      # one more for the semi-colon
      chars_since_last_newline: context.chars_since_last_newline + String.length(value) + 1
    ]

    if context.skip_comments do
      continue_lex(context, context_updates)
    else
      return_lex({Token.cmt(), value}, context, context_updates)
    end
  end

  # dqstring
  defp do_lex(%Context{src_rest: <<?", rest::binary>>} = context) do
    case parse_dqstring(rest) do
      # TODO: @see error logging paragraph in todo.txt. We are not able to provide location in file for these errors as of now
      {:error, msg} ->
        error_log_and_die(msg)

      {str, rest, count} ->
        context_updates = [
          src_rest: rest,
          chars_since_last_newline: count + 2 # +2 for the opening and closing quotes
        ]

        return_lex({Token.dqstring(), str}, context, context_updates)
    end
  end

  # identifier base case
  defp do_lex(%Context{} = context) do
    {{value, type}, rest} = parse_identifier(context)

    context_updates = [
      src_rest: rest,
      chars_since_last_newline: context.chars_since_last_newline + String.length(value)
    ]

    return_lex({type, value}, context, context_updates)
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

  defp parse_identifier(<<char, rest::binary>>, result) when valid_identifier_char(char) do
    parse_identifier(rest, [char | result])
  end

  defp parse_identifier(rest, result) do
    result =
      result
      |> Enum.reverse()
      |> List.to_string()

    type =
      if result in @keywords do
        Token.kwd()
      else
        Token.ident()
      end

    {{result, type}, rest}
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

  defp parse_comment(str, result \\ []) do
    case str do
      <<?\n, rest::binary>> ->
        return_comment("\n" <> rest, result)

      <<?\r, ?\n, rest::binary>> ->
        return_comment("\r\n" <> rest, result)

      <<c, rest::binary>> ->
        parse_comment(rest, [c | result])
    end
  end

  @compile {:inline, return_comment: 2}
  defp return_comment(rest, result) do
    result
    |> Enum.reverse()
    |> List.to_string()
    |> then(&{&1, rest})
  end

  defp parse_dqstring(str, result \\ [], count \\ 0)

  defp parse_dqstring(str, result, count) do
    case str do
      <<?\n, _rest::binary>> ->
        {:error, "multi-line strings are not supported yet™"}

      <<?\r, ?\n, _rest::binary>> ->
        {:error, "multi-line strings are not supported yet™"}

      <<?\\, c, rest::binary>> ->
        # TODO: idk if we should handle all of them ¯\_(ツ)_/¯
        #  \0 - Null byte
        #  \a - Bell
        #  \b - Backspace
        #  \t - Horizontal tab
        #  \n - Line feed (New lines)
        #  \v - Vertical tab
        #  \f - Form feed
        #  \r - Carriage return
        #  \e - Command Escape
        #  \s - Space
        #  \# - Returns the # character itself, skipping interpolation
        #  \\ - Single backslash
        #  \xNN - A byte represented by the hexadecimal NN
        #  \uNNNN - A Unicode code point represented by NNNN
        #  \u{NNNNNN} - A Unicode code point represented by NNNNNN

        {c, c_count} = case c do
          ?n -> {?\n, 2}
          ?t -> {?\t, 2}
          ?r -> {?\r, 2}
          _ -> {c, 1}
        end
        parse_dqstring(rest, [c | result], count + c_count)

      <<?", rest::binary>> ->
        result
        |> Enum.reverse()
        # |> List.to_string()
        |> then(&{&1, rest, count})

      <<c, rest::binary>> ->
        parse_dqstring(rest, [c | result], count + 1)

      _ ->
        {:error, "end of string not found"}
    end
  end
end
