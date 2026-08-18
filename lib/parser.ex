defmodule Elil.Parser do
  alias Elil.Lexer, as: Lexer
  require Elil.Utils
  import Elil.Utils

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
      def let(), do: :let
      def ident(), do: :ident
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
    {:ok, result} = parse_term_list(lexer_pid)
    {:ok, %Node{type: Node.Type.root(), params: result}}
  end

  defp parse_term_list(pid, acc \\ [], opts \\ []) when is_pid(pid) do
    case Lexer.current(pid) do
      # bootstrap the lexer
      nil ->
        case Lexer.shift(pid) do
          %Lexer{token: :oparen} ->
            parse_term_list(pid, acc)

          %Lexer{} = lexer ->
            Elil.Logger.error_log_and_die(
              Lexer.get_file_path(pid),
              lexer,
              "expected oparen, but got: :#{Atom.to_string(lexer.token)}"
            )
        end

      %Lexer{token: :cparen} = lexer ->
        # handle nested scopes. For root scopes, cparen should not be allowed
        case Keyword.get(opts, :expect_cparen) do
          nil ->
            Elil.Logger.error_log_and_die(
              Lexer.get_file_path(pid),
              lexer,
              "unexpected closing parentheses"
            )

          true ->
            {:ok, Enum.reverse(acc)}
        end

      %Lexer{token: :eof} = lexer ->
        # handle nested scopes. For root scopes, cparen should not be allowed
        case Keyword.get(opts, :expect_cparen) do
          true ->
            Elil.Logger.error_log_and_die(
              Lexer.get_file_path(pid),
              lexer,
              "unexpected EOF, expected closing parentheses"
            )

          v when v in [nil, false] ->
            {:ok, Enum.reverse(acc)}
        end

      %Lexer{token: :oparen} ->
        case Lexer.shift(pid) do
          # handle standalone terms
          %Lexer{token: token} when token in [:ident, :kwd] ->
            {:ok, term} = parse_term(pid)
            %Lexer{token: :cparen} = Lexer.current(pid)
            Lexer.shift(pid)
            parse_term_list(pid, [term | acc])

          # handle nested scopes
          %Lexer{token: :oparen} ->
            {:ok, list} = parse_term_list(pid, [], expect_cparen: true)
            %Lexer{token: :cparen} = Lexer.current(pid)
            Lexer.shift(pid)
            node = struct!(%Node{}, type: Node.Type.scope(), params: list)
            parse_term_list(pid, [node | acc])
        end
    end
  end

  defp parse_term(pid) do
    case Lexer.current(pid) do
      %Lexer{token: :ident} ->
        ident = parse_ident(pid)
        Lexer.shift(pid)
        params = parse_params(pid)
        node = struct!(%Node{}, type: Node.Type.expr(), body: ident, params: params)
        %Lexer{token: :cparen} = Lexer.current(pid)
        {:ok, node}

      %Lexer{token: :kwd} ->
        node = parse_kwd(pid)
        %Lexer{token: :cparen} = Lexer.current(pid)
        {:ok, node}

      %Lexer{token: token} when is_lit(token) ->
        lit = parse_lit(pid)
        node = %Node{type: Node.Type.lit(), body: lit}
        {:ok, node}

      %Lexer{} = lexer ->
        Elil.Logger.error_log_and_die(
          Lexer.get_file_path(pid),
          lexer,
          "a term has to begin with an identifier or a keyword, got #{Atom.to_string(lexer.token)}"
        )
    end
  end

  defp parse_ident(pid) when is_pid(pid) do
    case Lexer.current(pid) do
      %Lexer{token: :ident} = lexer ->
        lexer.value
    end
  end

  defp parse_params(pid, acc \\ []) when is_pid(pid) do
    case Lexer.current(pid) do
      %Lexer{token: :oparen} ->
        Lexer.shift(pid)
        {:ok, term} = parse_term(pid)
        %Lexer{token: :cparen} = Lexer.current(pid)
        Lexer.shift(pid)
        parse_params(pid, [term | acc])

      %Lexer{token: token} when is_lit(token) ->
        body = parse_lit(pid)
        Lexer.shift(pid)
        parse_params(pid, [%Node{type: Node.Type.lit(), body: body} | acc])

      # Identifier is used as an argument to e.g. a function.
      %Lexer{token: :ident} ->
        node = struct!(Node, type: Node.Type.ident(), body: parse_ident(pid))
        Lexer.shift(pid)
        parse_params(pid, [node | acc])

      %Lexer{token: :cparen} ->
        Enum.reverse(acc)
    end
  end

  defp parse_lit(pid) when is_pid(pid) do
    case Lexer.current(pid) do
      %Lexer{token: token} = lexer when is_lit(token) ->
        lexer.value

      %Lexer{} = lexer ->
        Elil.Logger.error_log_and_die(
          Lexer.get_file_path(pid),
          lexer,
          "a valid literal is expected when calling parse_lit binding, got: :#{Atom.to_string(lexer.token)}"
        )
    end
  end

  defp parse_kwd(pid) when is_pid(pid) do
    # TODO: maybe the pattern here should be more like parse_ident, where it simply parses the value
    #  instead of parsing the entire node. It makes for an inconsitent API, but it also consolidates
    #  the logic for "next token expectations" in a differnet place than the main parsing recursion.
    #  Also we do the building of the ident node both here and in the main recursion loop in parse_term.

    #  TLDR; I don't know which of the approaches are better, but the one explained here leaves for
    #  more flexibility in the future maybe.
    case Lexer.current(pid) do
      %Lexer{value: "let"} ->
        case Lexer.shift(pid) do
          %Lexer{token: :ident} ->
            ident = parse_ident(pid)
            Lexer.shift(pid)
            {:ok, term} = parse_term(pid)
            Lexer.shift(pid)
            %Node{type: Node.Type.let(), body: ident, params: [term]}

          %Lexer{} = lexer ->
            Elil.Logger.error_log_and_die(
              Lexer.get_file_path(pid),
              lexer,
              "a valid identifier is expected when doing a \"let\" binding, got: :#{Atom.to_string(lexer.token)}"
            )
        end

      %Lexer{value: "fn"} ->
        todo("parse_fn kwd")

      %Lexer{} = lexer ->
        todo("unhandled keyword: #{Atom.to_string(lexer.token)}")
    end
  end
end
