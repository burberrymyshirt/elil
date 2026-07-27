#!/usr/bin/env elixir

Code.require_file "./utils.exs"

defmodule Elil do
  defmodule Logger do
    def error_log_and_die(msg) when is_binary(msg) do
      error_log(msg)
      exit {:shutdown, 1}
    end

    def error_log_and_die(file_path, msg) when is_binary(file_path) and is_binary(msg) do
      error_log(file_path, msg)
      exit {:shutdown, 1}
    end

    def error_log_and_die(file_path, %Elil.Lexer{} = lexer, msg) when is_binary(file_path) and is_binary(msg) do
      error_log_and_die(file_path, {lexer.row, lexer.col}, msg)
    end

    def error_log_and_die(file_path, {row, col} = pos, msg) when is_integer(row) and is_integer(col) and is_binary(file_path) and is_binary(msg) do
      error_log(file_path, pos, msg)
      exit {:shutdown, 1}
    end

    # WANT: proper error logging with codes and ascii escape code colors and such
    def error_log(msg) when is_binary(msg), do: IO.puts msg

    def error_log(file_path, msg) when is_binary(file_path) and is_binary(msg) do
      error_log "#{file_path} #{msg}"
    end

    def error_log(file_path, {row, col},  msg) when is_binary(file_path) and is_integer(row) and is_integer(col) and is_binary(msg) do
      error_log "#{file_path}:#{row}:#{col} #{msg}"
    end
  end

  defmodule Evaluator do
    alias Elil.Lexer, as: Lexer
    require Utils
    import Utils
    require Elil.Logger
    import Elil.Logger

    defmodule Node do
      defstruct [
        :type,
        body: nil,
        params: [],
      ]

      defmodule Type do
        def expr(), do: :expr
        def scope(), do: :scope
        def lit(), do: :lit
      end
    end

    defguard is_lit(v) when v in [:int, :dqstring]

    def eval(file, file_path) when is_pid(file) or is_atom(file) do
      # WANT: we just assume file is a valid atom or pid, so add validate_file or something
      IO.read(file, :eof) |> eval(file_path)
    end

    def eval(file, file_path) when is_binary(file) do
      {:ok, lexer_pid} = GenServer.start_link(Lexer, {file_path, file}, [hibernate_after: 100])
      {:ok, results} = parse(lexer_pid)
      IO.write(:stdio, "results: ")
      dump(results);

      todo()
    end

    defp stop_parse(pid, result) do
      GenServer.stop(pid)
      {:ok, Enum.reverse(result)}
    end

    # TODO: This probably needs redoing. The API is very awkward to work with and it feels like error handling will be a bitch
    defp parse(pid, result \\ [])

    defp parse(pid, result) when is_list(result) do
      case Lexer.shift_token(pid) do
        %Lexer{token: :oparen} = lexer ->
          case parse_scope(pid, lexer) do
            %Node{} = node ->
              result = [node | result]
              parse(pid, result)
            {:error, msg} -> error_log_and_die(Lexer.get_file_path(pid), lexer, msg)
          end
        %Lexer{token: :eof} ->
          stop_parse(pid, result)
        %Lexer{} = lexer ->
          error_log_and_die(Lexer.get_file_path(pid), {lexer.row, lexer.col}, "unreachable")
      end
    end

    defp parse_scope(pid, %Lexer{token: :oparen} = _lexer) do
      node = %Node{}
      parse_scope(pid, Lexer.shift_token(pid), node)
    end

    defp parse_scope(pid, %Lexer{} = lexer) do
      # TODO: figure out if we just want to return {:error, msg} or this on failure.
      error_log_and_die(Lexer.get_file_path(pid), lexer, "Expected open parentheses")
    end

    defp parse_scope(pid, %Lexer{token: :oparen} = current_token, %Node{body: body} = node) when not is_nil(body) do
      parse_scope(pid, Lexer.shift_token(pid), struct!(node, [type: Node.Type.expr(), params: [parse_scope(pid, current_token) | node.params]]))
    end

    defp parse_scope(pid, %Lexer{token: :oparen} = current_token, %Node{type: nil, body: nil} = node) do
      # TODO: the comment below was made some time ago. I think this was meant
      #  to have the scope statements as parameters instead of body. That would
      #  also make handling of the ability to put multiple statements/expressions
      #  inside the scope-body way easier, rather than having to juggle body
      #  being either a %Node{} or a list of %Node{}, like this current implementation suggests.
      node = struct!(node, [type: Node.Type.scope(), body: parse_scope(pid, current_token)])
      # body = nil, so this can be used as an internal scope or whatever.
      # WANT: Like if you want to do an inner scope to not leak variables or something.
      parse_scope(pid, Lexer.shift_token(pid), node)
    end

    defp parse_scope(_pid, %Lexer{token: :cparen}, %Node{} = node) do
      # TODO: this becomes a way easier case to handle once we have the Lexer todo handled.
      #  Right now it is a bit awkward to check if we have to continue parsing inside the current scope or return the node
      #
      #  Maybe we could just check if the current node is of type: :scope, and continue in that case, because an expr will only have a single scope
      #  haven't really explored that idea, but it might be able to work.
      node
    end

    defp parse_scope(pid, %Lexer{token: :ident} = _lexer, %Node{body: body} = node) when not is_nil(body) do
      node = struct!(node, [type: Node.Type.expr(), params: parse_params(pid)])
      parse_scope(pid, Lexer.read_current_token(pid), node)
    end

    defp parse_scope(pid, %Lexer{token: :ident, value: value}, %Node{body: nil} = node) do
      node = struct!(node, [type: Node.Type.expr(), body: value])
      parse_scope(pid, Lexer.shift_token(pid), node)
    end

    defp parse_scope(pid, %Lexer{token: token} = _current_token, %Node{body: body} = node) when is_lit(token) and not is_nil(body) do
      node = struct!(node, [params: parse_params(pid)])
      # parse_params consumes the final closed paren, hence the read rather than shift
      parse_scope(pid, Lexer.read_current_token(pid), node)
    end

    defp parse_scope(pid, %Lexer{token: token} = current_token, %Node{body: body, params: params} = node) when is_lit(token) and is_nil(body) do
      node = struct!(node, [type: Node.Type.lit(), params: [parse_lit(current_token) | params]])
      parse_scope(pid, Lexer.shift_token(pid), node)
    end

    defp parse_scope(_pid, %Lexer{token: :eof} = _lexer, %Node{}) do
      {:error, "unexpected EOF"}
    end

    defp parse_scope(pid, %Lexer{token: token, row: row, col: col}, %Node{} = _node) do
      todo("unexpected token \":#{token}\" given to parse_scope at: #{Lexer.get_file_path(pid)}:#{row}:#{col}")
    end

    defp parse_lit(%Lexer{token: token, value: value}) when token === :int do
      value
    end

    defp parse_lit(%Lexer{token: token, value: value}) when token === :dqstring do
      # WANT: string interpolation
      value
    end

    defp parse_lit(%Lexer{token: token}) do
      todo("parse_lit with token: \":#{Atom.to_string(token)}\"")
    end

    defp parse_params(pid, result \\ [])

    defp parse_params(pid, result) when is_pid(pid) and is_list(result) do
      lexer = Lexer.read_current_token(pid)
      params = do_parse_params(lexer)
      case params do
        {:done} ->
          Enum.reverse(result)
        {:scope} ->
          parse_params(pid, {:continue, [%Node{type: Node.Type.expr(), body: parse_scope(pid, lexer)} | result]})
        {:ok, %Node{} = node} ->
          parse_params(pid, {:continue, [node | result]})
        {:error, msg} ->
          error_log_and_die(Lexer.get_file_path(pid), params, msg)
      end
    end

    defp parse_params(pid, {:continue, result}) when is_pid(pid) do
      Lexer.shift_token pid
      parse_params pid, result
    end

    defp do_parse_params(%Lexer{token: token} = lexer) when is_lit(token) do
      {:ok, %Node{type: Node.Type.lit(), body: parse_lit(lexer)}}
    end

    defp do_parse_params(%Lexer{token: :oparen} = _lexer) do
      {:scope}
    end

    defp do_parse_params(%Lexer{token: :cparen} = _lexer) do
      {:done}
    end

    defp do_parse_params(%Lexer{token: token}) when token === :eof do
      {:error, "unexpected \":#{Atom.to_string(token)}\""}
    end
  end

  defmodule Lexer do
    require Utils
    import Utils
    require Elil.Logger
    import Elil.Logger
    use GenServer

    @enforce_keys [:token, :value, :row, :col]
    defstruct [
      :token,
      :value,
      :row,
      :col,
    ]

    defmodule Context do
      @enforce_keys [:src_rest, :total_newlines, :chars_since_last_newline]
      defstruct [
        :src_rest,
        :total_newlines,
        :chars_since_last_newline,
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

    def read_current_token(pid) when is_pid(pid) do
      GenServer.call(pid, {:read_current_token})
    end

    def shift_token(pid) when is_pid(pid) do
      GenServer.call(pid, {:shift_token})
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
        chars_since_last_newline: 0,
      }
      {:ok, %LexerState{file_path: file_path, context: context, current_token: nil}}
    end

    # TODO: all of this shifting and read_current_token is a bit limiting.
    #  I would like a read-forward buffer that is saved in the state, so we
    #  can read multiple tokens without shifting. I feel like that would make
    #  the parser api much more usable, when creating "expect" functions or
    #  patterns, to better handle errors. In this case, shift would shift from
    #  the stack first, and then start pulling from the stream again once empty.
    @impl true
    def handle_call({:shift_token}, _from, %LexerState{} = lexer_state) do
      {:ok, %Context{} = context, %Lexer{} = lexer} = do_lex(lexer_state.context)
      {:reply, lexer, struct!(lexer_state, [context: context, current_token: lexer])}
    end

    @impl true
    def handle_call({:read_current_token}, _from, %LexerState{} = lexer_state) do
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
      value = "";
      context_updates = [];
      return_lex {Token.eof(), value}, context, context_updates
    end

    defp do_lex(%Context{src_rest: <<char, rest::binary>>} = context) when char in [?\s, ?\t] do
      context_updates = [src_rest: rest, chars_since_last_newline: context.chars_since_last_newline + 1]
      continue_lex context, context_updates
    end

    defp do_lex(%Context{src_rest: <<?\r, ?\n, rest::binary>>} = context) do
      context_updates = [
        src_rest: rest,
        chars_since_last_newline: 0,
        total_newlines: context.total_newlines + 1,
      ]
      continue_lex context, context_updates
    end

    defp do_lex(%Context{src_rest: <<?\n, rest::binary>>} = context) do
      context_updates = [
        src_rest: rest,
        chars_since_last_newline: 0,
        total_newlines: context.total_newlines + 1,
      ]
      continue_lex context, context_updates
    end

    #oparen
    defp do_lex(%Context{src_rest: <<?(, rest::binary>>} = context) do
      value = "("
      context_updates = [src_rest: rest, chars_since_last_newline: context.chars_since_last_newline + String.length(value)]
      return_lex {Token.oparen(), value}, context, context_updates
    end

    #cparen
    defp do_lex(%Context{src_rest: <<?), rest::binary>>} = context) do
      value = ")"
      context_updates = [src_rest: rest, chars_since_last_newline: context.chars_since_last_newline + String.length(value)]
      return_lex {Token.cparen(), value}, context, context_updates
    end

    #int
    defp do_lex(%Context{src_rest: <<char, _rest::binary>>} = context) when is_numeric(char) do
      {value, rest} = parse_integer(context)
      context_updates = [src_rest: rest, chars_since_last_newline: context.chars_since_last_newline + String.length(value)]
      return_lex {Token.int(), value}, context, context_updates
    end

    #dqstring
    defp do_lex(%Context{src_rest: <<?", rest::binary>>} = context) do
      # WANT: handle escaping and such

      charlist = String.to_charlist(rest)
      nl_index = Enum.find_index(charlist, &(&1 === ?\n))
      dq_index = (Enum.find_index charlist, &(&1 === ?"))
      if is_nil(dq_index) do
        error_log "invalid string found" # make this make sense <:-}
        exit {:shutdown, 1}
      end
      if nl_index < dq_index do
        # TODO: if we do decide to use multiline strings, we need to handle newlines as well
        todo "multiline strings are not implemented yet"
        exit {:shutdown, 1}
      end

      {value, rest} = String.split_at(rest, dq_index) # TODO: refactor line to parse_dqstring or something, like integer and identifier
      rest = chop_right(rest)
      context_updates = [src_rest: rest, chars_since_last_newline: context.chars_since_last_newline + String.length(value) + 2] # +2 for the surrounding quotes
      return_lex {Token.dqstring(), value}, context, context_updates
    end

    #identifier base case
    defp do_lex(%Context{} = context) do
      {value, rest} = parse_identifier(context)
      context_updates = [src_rest: rest, chars_since_last_newline: context.chars_since_last_newline + String.length(value)]
      return_lex {Token.ident(), value}, context, context_updates
    end

    defp continue_lex(%Context{} = context, context_updates) when is_list(context_updates) do
      do_lex struct!(context, context_updates)
    end

    defp return_lex({token, value}, %Context{} = context, context_updates) when is_list(context_updates) and is_atom(token) do
      lexer = %__MODULE__{
        token: token,
        value: value,
        row: Context.current_row(context),
        col: Context.current_column(context),
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
      |> then(&({&1, rest}))
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
      |> then(&({&1, rest}))
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
end

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
        Elil.Evaluator.eval(fd, file_path)
    end
end
