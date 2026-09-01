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
      @compile {:inline,
                root: 0,
                scope: 0,
                dqstr: 0,
                int: 0,
                let: 0,
                ident: 0,
                deffn: 0,
                cond_if: 0,
                bool_true: 0,
                bool_false: 0}
      def root(), do: :root
      def scope(), do: :scope
      def dqstr(), do: :dqstr
      def int(), do: :int
      def let(), do: :let
      def ident(), do: :ident
      def deffn(), do: :deffn
      def cond_if(), do: :cond_if
      def bool_true(), do: :bool_true
      def bool_false(), do: :bool_false
    end
  end

  defmodule Context do
    defstruct [
      :state,
      nested_level: 0,
      current_node: nil
    ]
  end

  # TODO: should be contained in one place. Types are also located in the evaluator.
  #  Also I don't know how we should handle users defining their own types. So this is temp only.
  #  Maybe the evaluator should just handle validating types i guess.
  @elil_types [:string, :int, :func, :mixed]

  defguardp is_valid_type(t) when is_atom(t) and t in @elil_types

  def parse(lexer_pid) when is_pid(lexer_pid) do
    {:ok, list} = parse_root_term_list(lexer_pid)
    {:ok, %Node{type: Node.Type.root(), params: list}}
  end

  defp parse_root_term_list(pid, acc \\ []) when is_pid(pid) and is_list(acc) do
    case Lexer.current(pid) do
      # bootstrap the lexer
      nil ->
        case Lexer.shift(pid) do
          %Lexer{token: :oparen} ->
            parse_root_term_list(pid, acc)

          %Lexer{} = lexer ->
            Elil.Logger.error_log_and_die(
              Lexer.get_file_path(pid),
              lexer,
              "expected \":oparen\", but got: :#{Atom.to_string(lexer.token)}"
            )
        end

      %Lexer{token: :eof} ->
        {:ok, Enum.reverse(acc)}

      # %Lexer{token: :cparen} = lexer ->
      #   Elil.Logger.error_log_and_die("@see logging errors", lexer, "unexpected closing parenthesis encountered")

      %Lexer{token: :oparen} ->
        case Lexer.shift(pid) do
          # handle nested scopes
          %Lexer{token: :oparen} ->
            {:ok, list} = parse_scope_term_list(pid)
            node = struct!(Node, type: Node.Type.scope(), params: list)
            parse_root_term_list(pid, [node | acc])

          # handle standalone terms
          %Lexer{} ->
            {:ok, term} = parse_term(pid)
            parse_root_term_list(pid, [term | acc])
        end
    end
  end

  defp parse_scope_term_list(pid, acc \\ []) when is_pid(pid) and is_list(acc) do
    case Lexer.current(pid) do
      %Lexer{token: :cparen} ->
        Lexer.shift(pid)
        {:ok, Enum.reverse(acc)}

      %Lexer{token: :oparen} ->
        case Lexer.shift(pid) do
          # handle standalone terms
          %Lexer{token: token} when token in [:ident, :kwd] ->
            {:ok, term} = parse_term(pid)
            parse_scope_term_list(pid, [term | acc])

          %Lexer{token: :oparen} ->
            {:ok, list} = parse_scope_term_list(pid)
            parse_scope_term_list(pid, [list | acc])
        end
    end
  end

  defp parse_term(pid) do
    case Lexer.current(pid) do
      %Lexer{token: :ident} ->
        ident = parse_ident(pid)
        {:ok, params} = parse_params(pid)
        node = struct!(Node, type: Node.Type.ident(), body: ident, params: params)
        {:ok, node}

      %Lexer{token: :kwd} ->
        node = parse_kwd(pid)
        {:ok, node}

      %Lexer{token: :bool_true} ->
        lit = parse_lit(pid)

        # parse_lit can't shift more than it already is, cause then we will end up skipping tokens.
        Lexer.shift(pid)
        node = %Node{type: Node.Type.bool_true(), body: lit}
        {:ok, node}

      %Lexer{token: :bool_false} ->
        lit = parse_lit(pid)

        # parse_lit can't shift more than it already is, cause then we will end up skipping tokens.
        Lexer.shift(pid)
        node = %Node{type: Node.Type.bool_false(), body: lit}
        {:ok, node}

      %Lexer{token: :dqstr} ->
        lit = parse_lit(pid)

        # parse_lit can't shift more than it already is, cause then we will end up skipping tokens.
        Lexer.shift(pid)
        node = %Node{type: Node.Type.dqstr(), body: lit}
        {:ok, node}

      %Lexer{token: :int} ->
        lit = parse_lit(pid)

        # parse_lit can't shift more than it already is, cause then we will end up skipping tokens.
        Lexer.shift(pid)
        node = %Node{type: Node.Type.int(), body: lit}
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
        Lexer.shift(pid)
        lexer.value
    end
  end

  defp parse_params(pid, acc \\ []) when is_pid(pid) do
    case Lexer.current(pid) do
      %Lexer{token: :oparen} ->
        Lexer.shift(pid)
        {:ok, term} = parse_term(pid)
        parse_params(pid, [term | acc])

      %Lexer{token: :dqstr} ->
        body = parse_lit(pid)
        parse_params(pid, [%Node{type: Node.Type.dqstr(), body: body} | acc])

      %Lexer{token: :int} ->
        body = parse_lit(pid)
        parse_params(pid, [%Node{type: Node.Type.int(), body: body} | acc])

      %Lexer{token: :bool_true} ->
        body = parse_lit(pid)
        parse_params(pid, [%Node{type: Node.Type.bool_true(), body: body} | acc])

      %Lexer{token: :bool_false} ->
        body = parse_lit(pid)
        parse_params(pid, [%Node{type: Node.Type.bool_false(), body: body} | acc])

      # Identifier is used as an argument to e.g. a function.
      %Lexer{token: :ident} ->
        node = struct!(Node, type: Node.Type.ident(), body: parse_ident(pid))
        parse_params(pid, [node | acc])

      %Lexer{token: :cparen} ->
        Lexer.shift(pid)
        {:ok, Enum.reverse(acc)}
    end
  end

  defp parse_lit(pid) when is_pid(pid) do
    case Lexer.current(pid) do
      %Lexer{token: :bool_true} = lexer ->
        Lexer.shift(pid)
        lexer.value

      %Lexer{token: :bool_false} = lexer ->
        Lexer.shift(pid)
        lexer.value

      %Lexer{token: :dqstr} = lexer ->
        Lexer.shift(pid)
        lexer.value

      %Lexer{token: :int} = lexer ->
        Lexer.shift(pid)
        lexer.value

      %Lexer{} = lexer ->
        Elil.Logger.error_log_and_die(
          Lexer.get_file_path(pid),
          lexer,
          "a valid literal is expected when calling parse_lit binding, got: :#{Atom.to_string(lexer.token)}"
        )
    end
  end

  defp parse_args(pid) when is_pid(pid) do
    # hard assert for now, could become less strict e.g. for functions that take no arguments.
    :ok = expect_token(Lexer.current(pid), :oparen)
    Lexer.shift(pid)
    do_parse_args(pid)
  end

  defp do_parse_args(pid, acc \\ []) do
    case Lexer.current(pid) do
      %Lexer{token: :cparen} ->
        Lexer.shift(pid)
        {:ok, Enum.reverse(acc)}

      lexer ->
        :ok = expect_token(lexer, :ident)
        ident = parse_ident(pid)
        %Lexer{} = current = Lexer.current(pid)
        :ok = expect_token(current, [:colon, :ident, :cparen])

        node =
          case current do
            %Lexer{token: :colon} ->
              %Lexer{} = type = Lexer.shift(pid)

              # TODO: should probably happen in the evaluator as we can't know the type here for sure. in the case where users get to define their own.
              :ok = expect_type(type)
              type_value = parse_ident(pid)

              struct!(Node,
                type: Node.Type.ident(),
                body: ident,
                params: [type: String.to_atom(type_value)]
              )

            # validated by previous expect
            _ ->
              struct!(Node, type: Node.Type.ident(), body: ident, params: [type: :mixed])
          end

        do_parse_args(pid, [node | acc])
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
            {:ok, term} = parse_params(pid)
            # hard assert for now.
            1 = length(term)
            %Node{type: Node.Type.let(), body: ident, params: term}

          %Lexer{} = lexer ->
            Elil.Logger.error_log_and_die(
              Lexer.get_file_path(pid),
              lexer,
              "a valid identifier is expected when doing a \"let\" binding, got: :#{Atom.to_string(lexer.token)}"
            )
        end

      %Lexer{value: "deffn"} ->
        Lexer.shift(pid)
        fn_name = parse_ident(pid)

        {:ok, args} = parse_args(pid)

        %Lexer{token: :oparen} = Lexer.current(pid)
        Lexer.shift(pid)

        {:ok, body} =
          parse_scope_term_list(pid)
          |> then(&{elem(&1, 0), struct!(Node, type: Node.Type.scope(), params: elem(&1, 1))})

        Lexer.shift(pid)

        params = [fn_args: args, fn_body: body]
        struct!(Node, type: Node.Type.deffn(), body: fn_name, params: params)

      %Lexer{value: "if"} ->
        %Lexer{token: :oparen} = Lexer.shift(pid)
        Lexer.shift(pid)
        {:ok, c} = parse_term(pid)
        Lexer.shift(pid)
        {:ok, t} = parse_term(pid)

        e =
          case Lexer.current(pid) do
            %Lexer{token: :oparen} ->
              Lexer.shift(pid)

              parse_term(pid)
              |> then(fn {:ok, e} -> e end)

            _ ->
              nil
          end

        # @see logging erros this just hard fails, it should probably have a nice message :)
        %Lexer{token: :cparen} = Lexer.current(pid)
        Lexer.shift(pid)
        struct!(Node, type: Node.Type.cond_if(), body: c, params: [then: t, else: e])

      %Lexer{} = lexer ->
        todo("unhandled keyword: \"#{lexer.value}\"")
    end
  end

  defp expect_token(%Lexer{} = lexer, expected_tokens)
       when is_list(expected_tokens) and length(expected_tokens) > 1 do
    case Enum.member?(expected_tokens, lexer.token) do
      true ->
        :ok

      # TODO: @see logging errors
      false ->
        expected_tokens
        |> Enum.map(fn t -> "\":#{Atom.to_string(t)}\"" end)
        |> Enum.join(", ")
        |> then(
          &Elil.Logger.error_log_and_die(
            "expected one of [\":#{&1}\"], but got \":#{Atom.to_string(lexer.token)}\""
          )
        )

        :err
    end
  end

  defp expect_token(%Lexer{} = lexer, expected_token)
       when is_list(expected_token) and length(expected_token) <= 1 do
    expect_token(lexer, List.first!(expected_token))
  end

  defp expect_token(%Lexer{} = lexer, expected_token) when is_atom(expected_token) do
    case lexer.token do
      ^expected_token ->
        :ok

      # TODO: @see logging errors
      _ ->
        Elil.Logger.error_log_and_die(
          "expected \":#{Atom.to_string(expected_token)}\", but got \":#{Atom.to_string(lexer.token)}\""
        )

        :err
    end
  end

  defp expect_type(%Lexer{} = lexer) do
    expect_token(lexer, :ident)

    case String.to_atom(lexer.value) do
      l when is_valid_type(l) ->
        :ok

      _ ->
        Elil.Logger.error_log_and_die(
          "unexpected type. TODO: move this error from parser to evaluator."
        )
    end
  end
end
