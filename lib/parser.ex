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
          %Node{type: type, body: nil} = node when type in [:expr, :scope] ->
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

              %Lexer{token: :oparen} ->
                new_context =
                  struct!(Context,
                    state: :parse_body,
                    current_node: %Node{type: Node.Type.expr()},
                    nested_level: context.nested_level + 1
                  )

                Lexer.shift_token(pid)

                {:node_parsed, %Node{} = new_node} = do_parse(pid, new_context, result)

                node =
                  case node do
                    %Node{body: nil} = node ->
                      struct!(node, type: Node.Type.scope(), params: [new_node | node.params])

                      ### Compiler says the below is never matched, but keep it commented out for now, cause I feel like it might be used in the future
                      # %Node{} = node ->
                      #   struct!(node, type: Node.Type.expr(), params: [new_node| node.params])
                      # _ -> unreachable()
                  end

                context = struct!(context, state: :parse_body, current_node: node)
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

              %Lexer{token: :cparen} when context.nested_level > 1 ->
                Lexer.shift_token(pid)
                node = struct!(node, params: Enum.reverse(node.params))
                {:node_parsed, node}

              %Lexer{token: token} = lexer when is_lit(token) ->
                new_node = %Node{type: Node.Type.lit(), body: lexer.value}
                node = struct!(node, params: [new_node | node.params])
                context = struct!(context, current_node: node, state: :parse_params)
                Lexer.shift_token(pid)
                do_parse(pid, context, result)

              %Lexer{token: :oparen} ->
                Lexer.shift_token(pid)

                new_context =
                  struct!(Context,
                    current_node: %Node{type: Node.Type.expr()},
                    nested_level: context.nested_level + 1,
                    state: :parse_body
                  )

                {:node_parsed, new_node} = do_parse(pid, new_context, result)

                node = struct!(node, params: [new_node | node.params])

                context =
                  struct!(context,
                    current_node: node,
                    state: :parse_params
                  )

                do_parse(pid, context, result)

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
