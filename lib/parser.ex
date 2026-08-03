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

  defp parse_scope(pid, %Lexer{token: :oparen} = _current_token, %Node{body: body} = node)
       when not is_nil(body) do
    parse_scope(
      pid,
      Lexer.shift_token(pid),
      struct!(node,
        type: Node.Type.expr(),
        params: [parse_params(pid)]
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

  defp parse_scope(pid, %Lexer{token: :cparen}, %Node{} = node) do
    # TODO: this becomes a way easier case to handle once we have the Lexer todo handled.
    #  Right now it is a bit awkward to check if we have to continue parsing inside the current scope or return the node
    #
    #  Maybe we could just check if the current node is of type: :scope, and continue in that case, because an expr will only have a single scope
    #  haven't really explored that idea, but it might be able to work.
    Lexer.shift_token(pid)
    node
  end

  defp parse_scope(pid, %Lexer{token: :ident} = _lexer, %Node{body: body} = node)
       when not is_nil(body) do
    node = struct!(node, type: Node.Type.expr(), params: parse_params(pid))
    parse_scope(pid, Lexer.get_current_token(pid), node)
  end

  defp parse_scope(pid, %Lexer{token: :ident, value: value}, %Node{body: nil} = node) do
    node = struct!(node, type: Node.Type.expr(), body: value)
    parse_scope(pid, Lexer.shift_token(pid), node)
  end

  defp parse_scope(pid, %Lexer{token: token} = _current_token, %Node{body: body} = node)
       when is_lit(token) and not is_nil(body) do
    node = struct!(node, params: parse_params(pid))
    # parse_params consumes the final closed paren, hence the read rather than shift
    parse_scope(pid, Lexer.get_current_token(pid), node)
  end

  defp parse_scope(
         pid,
         %Lexer{token: token} = _current_token,
         %Node{body: body} = node
       )
       when is_lit(token) and is_nil(body) do
    node = struct!(node, type: Node.Type.lit(), params: parse_params(pid))
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
    lexer = Lexer.get_current_token(pid)
    params = do_parse_params(lexer)

    dump(params)

    case params do
      {:done} ->
        Enum.reverse(result)

      {:scope} ->
        parsed_scope = parse_scope(pid, lexer)

        todo(
          "the parse_scope above consumes the cparen meant to close this param, so I don't know how to handle that."
        )

        parse_params(
          pid,
          {:continue, [%Node{type: Node.Type.expr(), body: parsed_scope} | result]}
        )

      {:ok, %Node{} = node} ->
        parse_params(pid, {:continue_shift, [node | result]})

      {:error, msg} ->
        error_log_and_die(Lexer.get_file_path(pid), lexer, msg)
    end
  end

  defp parse_params(pid, {:continue, result}) when is_pid(pid) do
    parse_params(pid, result)
  end

  defp parse_params(pid, {:continue_shift, result}) when is_pid(pid) do
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

defmodule Elil.Parser2 do
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
      def root(), do: :root
      def expr(), do: :expr
      def scope(), do: :scope
      def lit(), do: :lit
    end
  end

  defmodule Context do
    defstruct [
      :state,
      nested_level: 0,
      current_node: nil
    ]
  end

  defguard is_lit(v) when v in [:int, :dqstring]

  def parse(lexer_pid) when is_pid(lexer_pid) do
    do_parse(lexer_pid)
  end

  defp do_parse(pid, state \\ :start, result \\ [])

  defp do_parse(pid, :start, result) do
    # bootstrapping the lexer
    Lexer.shift_token(pid)
    do_parse(pid, struct!(Context, state: :continue), result)
  end

  defp do_parse(pid, %Context{} = context, result) do
    case context.state do
      :continue ->
        case Lexer.get_current_token(pid) do
          %Lexer{token: :eof} ->
            stop_parse(result)

          %Lexer{token: :oparen} ->
            node = struct!(%Node{}, type: Node.Type.expr())
            Lexer.shift_token(pid)

            context =
              struct!(context,
                state: :parse_body,
                current_node: node,
                nested_level: context.nested_level + 1
              )

            do_parse(pid, context, result)
        end

      :parse_body ->
        case context.current_node do
          %Node{type: :expr, body: nil} = node ->
            case Lexer.get_current_token(pid) do
              %Lexer{token: :cparen} when context.nested_level === 1 ->
                Lexer.shift_token(pid)

                context =
                  struct!(context,
                    state: :continue,
                    nested_level: context.nested_level - 1,
                    current_node: nil
                  )

                do_parse(pid, context, [node | result])

              %Lexer{token: :ident} = lexer ->
                node = struct!(node, body: lexer.value)
                context = struct!(context, current_node: node, state: :parse_params)
                Lexer.shift_token(pid)
                do_parse(pid, context, result)

              %Lexer{token: :oparen} = lexer ->
                new_context =
                  struct!(Context,
                    state: :continue,
                    current_node: %Node{type: Node.Type.expr()},
                    nested_level: context.nested_level + 1
                  )

                # I really don't know how to do about this. Hack the scopes to
                # collapse nested results? Read forward in the Lexer, and just
                # handle it inline rather than a recursive call to do_parse/3?
                #
                # The annoying thing is that we cannot parse references to struct
                # instances through the functions, so we have to handle this via a return type.
                todo("figure out how to handle nested scopes in this fuckass machine.")
                do_parse(pid, new_context, result)
                node = struct!(node, body: lexer.value)
                context = struct!(context, current_node: node, state: :parse_params)
                Lexer.shift_token(pid)
                do_parse(pid, context, result)

              %Lexer{} = lexer ->
                error_log_and_die(
                  Lexer.get_file_path(pid),
                  lexer,
                  "unexpected token: \":#{Atom.to_string(lexer.token)}\" found, expected \":ident\""
                )
            end
        end

      :parse_params ->
        case context.current_node do
          %Node{body: body} = node when not is_nil(body) ->
            case Lexer.get_current_token(pid) do
              %Lexer{token: :cparen} when context.nested_level === 1 ->
                Lexer.shift_token(pid)

                context =
                  struct!(context,
                    state: :continue,
                    nested_level: context.nested_level - 1,
                    current_node: nil
                  )

                do_parse(pid, context, [node | result])

              %Lexer{token: token} = lexer when is_lit(token) ->
                new_node = %Node{type: Node.Type.lit(), body: lexer.value}
                node = struct!(node, params: [new_node | node.params])
                context = struct!(context, current_node: node, state: :parse_params)
                Lexer.shift_token(pid)
                do_parse(pid, context, result)

              %Lexer{token: :oparen} ->
                Lexer.shift_token(pid)

                context =
                  struct!(context,
                    nested_level: context.nested_level - 1,
                    current_node: todo(),
                    state: :parse_body
                  )

                do_parse(pid, context, result)

              # new_node = struct!(Node, type: Node.Type.expr(), body: parse)

              %Lexer{} = lexer ->
                error_log_and_die(
                  Lexer.get_file_path(pid),
                  lexer,
                  "unexpected token: \":#{Atom.to_string(lexer.token)}\" found, expected one of \"[:dqstring, :int]\""
                )
            end
        end

      {:append_result, %Node{} = node} ->
        Lexer.shift_token(pid)
        do_parse(pid, :continue, [node | result])

      v ->
        dump(v)
        error_log_and_die("din mor er grim")
        todo("parse_node")
    end
  end

  defp stop_parse(result) do
    {:ok, struct!(%Node{type: Node.Type.root(), params: Enum.reverse(result)})}
  end
end
