#!/usr/bin/env elixir

Code.require_file "./utils.exs"

defmodule Elil do
  defmodule Logger do
    def error_log_and_die(msg) do
      error_log(msg)
      exit {:shutdown, 1}
    end

    def error_log_and_die(file_path, msg) do
      error_log(file_path, msg)
      exit {:shutdown, 1}
    end

    def error_log_and_die(file_path, pos, msg) do
      error_log(file_path, pos,  msg)
      exit {:shutdown, 1}
    end

    # TODO: proper error logging with codes and ascii escape code colors and such
    def error_log(msg), do: IO.puts msg

    def error_log(file_path, msg), do: error_log "#{file_path} #{msg}"

    def error_log(file_path, {row, col},  msg), do: error_log "#{file_path}:#{row}:#{col} #{msg}"
  end

  defmodule Evaluator do
    alias Elil.Lexer, as: Lexer
    require Utils
    import Utils
    require Elil.Logger
    import Elil.Logger

    defmodule Scope do
      defstruct [
        :type,
        body: nil,
        params: [],
      ]

      defmodule Type do
        def expr(), do: :expr
        def lit(), do: :lit
      end
    end

    defguard is_lit(v) when v in [:int, :dqstring]

    def eval(file, file_path) when is_pid(file) or is_atom(file) do
      # TODO: we just assume file is a valid atom or pid, so add validate_file or something
      IO.read(file, :eof) |> eval(file_path)
    end

    def eval(file, file_path) when is_binary(file) do
      {:ok, lexer_pid} = GenServer.start_link(Lexer, {file_path, file}, [hibernate_after: 100])
      {:ok, results} = parse(lexer_pid)
      dump(results)

      todo()
    end

    defp stop_parse(pid, result) do
      GenServer.stop(pid)
      {:ok, result}
    end

    defp parse(pid, result \\ [])

    defp parse(pid, result) when is_list(result) do
      case Lexer.get_next_token(pid) do
        %Lexer{token: :oparen} = lexer ->
          case parse_scope(pid, lexer) do
            %Scope{} = scope ->
              result = [scope | result]
              parse(pid, result)
            {:error, _msg} -> todo(":error after parse_scope in parse")
          end
        %Lexer{token: :eof} ->
          stop_parse(pid, result)
        %Lexer{} = lexer ->
          error_log_and_die(Lexer.get_file_path(pid), {lexer.row, lexer.col}, "unreachable")
      end
    end

    defp parse_scope(pid, %Lexer{token: :oparen} = _lexer) do
      scope = %Scope{}
      parse_scope(pid, Lexer.get_next_token(pid), scope)
    end

    defp parse_scope(pid, %Lexer{row: row, col: col} = _lexer) do
      # TODO: figure out if we just want to return {:error, msg} or this on failure.
      error_log_and_die(Lexer.get_file_path(pid), {row, col}, "Expected open parentheses")
    end

    defp parse_scope(pid, %Lexer{token: :oparen} = current_token, %Scope{body: body, params: args} = scope) when not is_nil(body) do
      parse_scope(pid, Lexer.get_next_token(pid), struct!(scope, [type: :expr, args: [parse_scope(pid, current_token) | args]]))
    end

    defp parse_scope(pid, %Lexer{token: :oparen} = current_token, %Scope{params: args} = scope) do
      # body = nil, so this can be used as an internal scope or whatever.
      # TODO: Like if you want to do an inner scope to not leak variables or something.
      parse_scope(pid, Lexer.get_next_token(pid), struct!(scope, [type: :expr, body: nil, params: [parse_scope(pid, current_token) | args]]))
    end

    defp parse_scope(_pid, %Lexer{token: :cparen}, %Scope{} = scope) do
      scope
    end

    defp parse_scope(pid, %Lexer{token: :ident, value: value}, %Scope{body: body, params: params} = scope) when not is_nil(body) do
      scope = struct!(scope, [type: Scope.Type.expr(), params: [parse_params(pid) | params]])
      parse_scope(pid, Lexer.get_next_token(pid), scope)
    end

    defp parse_scope(pid, %Lexer{token: :ident, value: value}, %Scope{body: body} = scope) do
      scope = struct!(scope, [type: Scope.Type.expr(), body: value])
      parse_scope(pid, Lexer.get_next_token(pid), scope)
    end

    # TODO: this guard should probably not be nessecery, as it is handled by the parse_lit pattern matching, but I am not too sure
    defp parse_scope(pid, %Lexer{token: token} = current_token, %Scope{body: body, params: params} = scope) when is_lit(token) and is_nil(body) do
      struct!(scope, [type: Scope.Type.lit(), params: [parse_lit(current_token) | params]])
      parse_scope(pid, Lexer.get_next_token(pid), scope)
    end

    defp parse_scope(pid, %Lexer{token: token} = current_token, %Scope{body: body} = scope) when is_lit(token) and not is_nil(body) do
      struct!(scope, [type: Scope.Type.lit(), body: parse_lit(current_token)])
      parse_scope(pid, Lexer.get_next_token(pid), scope)
    end

    defp parse_scope(_pid, %Lexer{token: :eof}, %Scope{}) do
      {:error, "unexpected EOF"}
    end

    defp parse_scope(pid, %Lexer{token: token, row: row, col: col}, %Scope{} = _scope) do
      todo("unexpected token \":#{token}\" given to parse_scope at: #{Lexer.get_file_path(pid)}:#{row}:#{col}")
    end

    defp parse_lit(%Lexer{token: token, value: value}) when token === :int do
      value
    end

    defp parse_lit(%Lexer{token: token, value: value}) when token === :dqstring do
      # TODO: string interpolation
      value
    end

    defp parse_lit(%Lexer{token: token}) do
      todo("parse_lit with token: #{Atom.to_string(token)}")
    end

    defp parse_params(pid, result \\ []) do
      todo("this should go though parse_scope, as a parameter to a function can also be an evaluated expr")
        [parse_params(Lexer.get_next_token(pid), result) | result]
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
      defstruct [:file_path, :context]
    end

    def get_next_token(pid) when is_pid(pid) do
      GenServer.call(pid, {:next_token}) |> dump()
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
      {:ok, %LexerState{file_path: file_path, context: context}}
    end

    @impl true
    def handle_call({:next_token}, _from, %LexerState{context: context} = lexer_state) do
      {:ok, %Context{} = context, %Lexer{} = lexer} = do_lex(context)
      {:reply, lexer, struct!(lexer_state, [context: context])}
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
      # TODO: handle escaping and such

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

      {value, rest} = String.split_at(rest, dq_index) # TODO: refactor to parse_dqstring or something, like integer and identifier
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
        Elil.Evaluator.eval(fd, file_path)
    end
end
