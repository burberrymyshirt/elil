defmodule Elil.Parser do
  import Elil.Logger
  import Elil.Utils
  alias Elil.Lexer, as: Lexer

  defmodule Node do
    defstruct [
      :type,
      body: nil,
      params: []
    ]

    defmodule Type do
      def expr(), do: :expr
      def scope(), do: :scope
      def lit(), do: :lit
    end
  end

  defguard is_lit(v) when v in [:int, :dqstring]

  defp stop_parse(pid, result) do
    GenServer.stop(pid)
    {:ok, Enum.reverse(result)}
  end

  # TODO: This probably needs redoing. The API is very awkward to work with and it feels like error handling will be a bitch
  def parse(pid, result \\ [])

  def parse(pid, result) when is_list(result) do
    case Lexer.shift_token(pid) do
      %Lexer{token: :oparen} = lexer ->
        case parse_scope(pid, lexer) do
          %Node{} = node ->
            result = [node | result]
            parse(pid, result)

          {:error, msg} ->
            error_log_and_die(Lexer.get_file_path(pid), lexer, msg)
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

  defp parse_scope(pid, %Lexer{token: :oparen} = current_token, %Node{body: body} = node)
       when not is_nil(body) do
    parse_scope(
      pid,
      Lexer.shift_token(pid),
      struct!(node,
        type: Node.Type.expr(),
        params: [parse_scope(pid, current_token) | node.params]
      )
    )
  end

  defp parse_scope(
         pid,
         %Lexer{token: :oparen} = current_token,
         %Node{type: nil, body: nil} = node
       ) do
    # TODO: the comment below was made some time ago. I think this was meant
    #  to have the scope statements as parameters instead of body. That would
    #  also make handling of the ability to put multiple statements/expressions
    #  inside the scope-body way easier, rather than having to juggle body
    #  being either a %Node{} or a list of %Node{}, like this current implementation suggests.
    node = struct!(node, type: Node.Type.scope(), body: parse_scope(pid, current_token))
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

  defp parse_scope(pid, %Lexer{token: :ident} = _lexer, %Node{body: body} = node)
       when not is_nil(body) do
    node = struct!(node, type: Node.Type.expr(), params: parse_params(pid))
    parse_scope(pid, Lexer.read_current_token(pid), node)
  end

  defp parse_scope(pid, %Lexer{token: :ident, value: value}, %Node{body: nil} = node) do
    node = struct!(node, type: Node.Type.expr(), body: value)
    parse_scope(pid, Lexer.shift_token(pid), node)
  end

  defp parse_scope(pid, %Lexer{token: token} = _current_token, %Node{body: body} = node)
       when is_lit(token) and not is_nil(body) do
    node = struct!(node, params: parse_params(pid))
    # parse_params consumes the final closed paren, hence the read rather than shift
    parse_scope(pid, Lexer.read_current_token(pid), node)
  end

  defp parse_scope(
         pid,
         %Lexer{token: token} = current_token,
         %Node{body: body, params: params} = node
       )
       when is_lit(token) and is_nil(body) do
    node = struct!(node, type: Node.Type.lit(), params: [parse_lit(current_token) | params])
    parse_scope(pid, Lexer.shift_token(pid), node)
  end

  defp parse_scope(_pid, %Lexer{token: :eof} = _lexer, %Node{}) do
    {:error, "unexpected EOF"}
  end

  defp parse_scope(pid, %Lexer{token: token, row: row, col: col}, %Node{} = _node) do
    todo(
      "unexpected token \":#{token}\" given to parse_scope at: #{Lexer.get_file_path(pid)}:#{row}:#{col}"
    )
  end

  defp parse_lit(%Lexer{token: token, value: value}) when token === :int do
    value
  end

  defp parse_lit(%Lexer{token: token, value: value}) when token === :dqstring do
    # WANT: string interpolation
    value
  end

  defp parse_params(pid, result \\ [])

  defp parse_params(pid, result) when is_pid(pid) and is_list(result) do
    lexer = Lexer.read_current_token(pid)
    params = do_parse_params(lexer)

    case params do
      {:done} ->
        Enum.reverse(result)

      {:scope} ->
        parse_params(
          pid,
          {:continue, [%Node{type: Node.Type.expr(), body: parse_scope(pid, lexer)} | result]}
        )

      {:ok, %Node{} = node} ->
        parse_params(pid, {:continue, [node | result]})

      {:error, msg} ->
        error_log_and_die(Lexer.get_file_path(pid), lexer, msg)
    end
  end

  defp parse_params(pid, {:continue, result}) when is_pid(pid) do
    Lexer.shift_token(pid)
    parse_params(pid, result)
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
