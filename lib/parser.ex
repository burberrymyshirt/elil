defmodule Elil.Parser do
  alias Elil.Lexer
  alias Elil.Lexer.Token
  alias Elil.Utils.SourceLocation
  import Elil.Utils
  require Elil.Utils

  defmodule Node do
    @enforce_keys :source_location
    defstruct [
      :type,
      :source_location,
      body: nil,
      params: []
    ]

    defmodule Type do
      @compile {:inline,
                root: 0,
                scope: 0,
                fn_body: 0,
                dqstr: 0,
                int: 0,
                let: 0,
                lt: 0,
                ass: 0,
                ident: 0,
                deffn: 0,
                cond_if: 0,
                bool_true: 0,
                bool_false: 0}
      def root(), do: :root
      def scope(), do: :scope
      def fn_body(), do: :fn_body
      def dqstr(), do: :dqstr
      def int(), do: :int
      def let(), do: :let
      def lt(), do: :lt
      def ass(), do: :ass
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

  def parse(lexer_pid) when is_pid(lexer_pid) do
    {:ok, list} = parse_root_term_list(lexer_pid)

    {:ok,
     %Node{
       type: Node.Type.root(),
       params: list,
       source_location:
         struct!(SourceLocation,
           row: 0,
           column: 0,
           file_path: Lexer.get_file_path(lexer_pid)
         )
     }}
  end

  defp parse_root_term_list(pid, acc \\ []) when is_pid(pid) and is_list(acc) do
    case Lexer.current(pid) do
      # bootstrap the lexer
      nil ->
        case Lexer.shift(pid) do
          %Token{token: :oparen} ->
            parse_root_term_list(pid, acc)

          %Token{} = lexer ->
            Elil.Logger.error_log_and_die(
              lexer,
              "expected \":oparen\", but got: :#{Atom.to_string(lexer.token)}"
            )
        end

      %Token{token: :eof} ->
        {:ok, Enum.reverse(acc)}

      # %Token{token: :cparen} = lexer ->
      #   Elil.Logger.error_log_and_die("@see logging errors", lexer, "unexpected closing parenthesis encountered")

      %Token{token: :oparen} ->
        case Lexer.shift(pid) do
          # handle nested scopes
          %Token{token: :oparen} = lexer ->
            {:ok, list} = parse_scope_term_list(pid)

            node =
              struct!(Node,
                type: Node.Type.scope(),
                params: list,
                source_location: lexer.source_location
              )

            parse_root_term_list(pid, [node | acc])

          # handle standalone terms
          %Token{} ->
            {:ok, term} = parse_term(pid)
            parse_root_term_list(pid, [term | acc])
        end
    end
  end

  defp parse_scope_term_list(pid, acc \\ [])
       when is_pid(pid) and is_list(acc) do
    case Lexer.current(pid) do
      %Token{token: :cparen} ->
        Lexer.shift(pid)
        {:ok, Enum.reverse(acc)}

      %Token{token: :oparen} ->
        case Lexer.shift(pid) do
          # handle standalone terms
          %Token{token: token} when token in [:ident, :kwd] ->
            {:ok, term} = parse_term(pid)
            parse_scope_term_list(pid, [term | acc])

          %Token{token: :oparen} ->
            {:ok, list} = parse_scope_term_list(pid)
            parse_scope_term_list(pid, [list | acc])
        end

      %Token{} ->
        {:err, "A scope is expected to start with an opening parenthesis"}
    end
  end

  defp parse_term(pid) do
    case Lexer.current(pid) do
      %Token{token: :ident} = lexer ->
        ident = parse_ident(pid)
        {:ok, params} = parse_params(pid)

        node =
          struct!(Node,
            type: Node.Type.ident(),
            body: ident,
            params: params,
            source_location: lexer.source_location
          )

        {:ok, node}

      %Token{token: :kwd} ->
        node = parse_kwd(pid)
        {:ok, node}

      %Token{token: :bool_true} = lexer ->
        lit = parse_lit(pid)

        # parse_lit can't shift more than it already is, cause then we will end up skipping tokens.
        Lexer.shift(pid)

        node =
          struct!(Node,
            type: Node.Type.bool_true(),
            body: lit,
            source_location: lexer.source_location
          )

        {:ok, node}

      %Token{token: :bool_false} = lexer ->
        lit = parse_lit(pid)

        # parse_lit can't shift more than it already is, cause then we will end up skipping tokens.
        Lexer.shift(pid)

        node =
          struct!(Node,
            type: Node.Type.bool_false(),
            body: lit,
            source_location: lexer.source_location
          )

        {:ok, node}

      %Token{token: :dqstr} = lexer ->
        lit = parse_lit(pid)

        # parse_lit can't shift more than it already is, cause then we will end up skipping tokens.
        Lexer.shift(pid)

        node =
          struct!(Node,
            type: Node.Type.dqstr(),
            body: lit,
            source_location: lexer.source_location
          )

        {:ok, node}

      %Token{token: :int} = lexer ->
        lit = parse_lit(pid)

        # parse_lit can't shift more than it already is, cause then we will end up skipping tokens.
        Lexer.shift(pid)

        node =
          struct!(Node,
            type: Node.Type.int(),
            body: lit,
            source_location: lexer.source_location
          )

        {:ok, node}

      %Token{} = lexer ->
        Elil.Logger.error_log_and_die(
          lexer,
          "a term has to begin with an identifier or a keyword, got #{Atom.to_string(lexer.token)}"
        )
    end
  end

  defp parse_ident(pid) when is_pid(pid) do
    case Lexer.current(pid) do
      %Token{token: :ident} = lexer ->
        Lexer.shift(pid)
        lexer.value
    end
  end

  defp parse_params(pid, acc \\ []) when is_pid(pid) do
    case Lexer.current(pid) do
      %Token{token: :oparen} ->
        Lexer.shift(pid)
        {:ok, term} = parse_term(pid)
        parse_params(pid, [term | acc])

      %Token{token: :dqstr} = lexer ->
        body = parse_lit(pid)

        parse_params(pid, [
          struct!(Node,
            type: Node.Type.dqstr(),
            body: body,
            source_location: lexer.source_location
          )
          | acc
        ])

      %Token{token: :int} = lexer ->
        body = parse_lit(pid)

        parse_params(pid, [
          struct!(Node,
            type: Node.Type.int(),
            body: body,
            source_location: lexer.source_location
          )
          | acc
        ])

      %Token{token: :bool_true} = lexer ->
        body = parse_lit(pid)

        parse_params(pid, [
          struct!(Node,
            type: Node.Type.bool_true(),
            body: body,
            source_location: lexer.source_location
          )
          | acc
        ])

      %Token{token: :bool_false} = lexer ->
        body = parse_lit(pid)

        parse_params(pid, [
          struct!(Node,
            type: Node.Type.bool_false(),
            body: body,
            source_location: lexer.source_location
          )
          | acc
        ])

      # Identifier is used as an argument to e.g. a function.
      %Token{token: :ident} = lexer ->
        node =
          struct!(Node,
            type: Node.Type.ident(),
            body: parse_ident(pid),
            source_location: lexer.source_location
          )

        parse_params(pid, [node | acc])

      %Token{token: :cparen} ->
        Lexer.shift(pid)
        {:ok, Enum.reverse(acc)}
    end
  end

  defp parse_lit(pid) when is_pid(pid) do
    case Lexer.current(pid) do
      %Token{token: :bool_true} = lexer ->
        Lexer.shift(pid)
        lexer.value

      %Token{token: :bool_false} = lexer ->
        Lexer.shift(pid)
        lexer.value

      %Token{token: :dqstr} = lexer ->
        Lexer.shift(pid)
        lexer.value

      %Token{token: :int} = lexer ->
        Lexer.shift(pid)
        lexer.value

      %Token{} = lexer ->
        Elil.Logger.error_log_and_die(
          lexer,
          "a valid literal is expected when calling parse_lit binding, got: :#{Atom.to_string(lexer.token)}"
        )
    end
  end

  defp parse_func_params(pid) when is_pid(pid) do
    # hard assert for now, could become less strict e.g. for functions that take no arguments.
    :ok = expect_token(Lexer.current(pid), :oparen)
    Lexer.shift(pid)
    do_parse_func_params(pid)
  end

  defp do_parse_func_params(pid, acc \\ []) do
    case Lexer.current(pid) do
      %Token{token: :cparen} ->
        Lexer.shift(pid)
        {:ok, Enum.reverse(acc)}

      lexer ->
        :ok = expect_token(lexer, :ident)
        ident = parse_ident(pid)
        %Token{} = current = Lexer.current(pid)
        :ok = expect_token(current, [:colon, :ident, :cparen])

        node =
          case current do
            %Token{token: :colon} ->
              %Token{} = type = Lexer.shift(pid)
              :ok = expect_token(type, :ident)
              type_ident = parse_ident(pid)

              struct!(Node,
                type: Node.Type.ident(),
                body: ident,
                params: [type: String.to_atom(type_ident)],
                source_location: type.source_location
              )

            # validated by previous expect
            _ ->
              struct!(Node,
                type: Node.Type.ident(),
                body: ident,
                params: [type: :mixed],
                source_location: current.source_location
              )
          end

        do_parse_func_params(pid, [node | acc])
    end
  end

  defp parse_kwd(pid) when is_pid(pid) do
    # TODO: maybe the pattern here should be more like parse_ident, where it simply parses the value
    #  instead of parsing the entire node. It makes for an inconsitent API, but it also consolidates
    #  the logic for "next token expectations" in a differnet place than the main parsing recursion.
    #  Also we do the building of the ident node both here and in the main recursion loop in parse_term.

    #  TLDR; I don't know which of the approaches are better, but the one explained here leaves for
    #  more flexibility in the future maybe.

    # TODO: much of this code looks similar. I feel like we could do it in a much simpler manner.
    #  Especially since much of it looks like something out of parse_term() when hitting an ident.
    case Lexer.current(pid) do
      %Token{value: "let"} ->
        case Lexer.shift(pid) do
          %Token{token: :ident} = lexer ->
            ident = parse_ident(pid)
            {:ok, term} = parse_params(pid)
            # hard assert for now.
            1 = length(term)

            struct!(Node,
              type: Node.Type.let(),
              body: ident,
              params: term,
              source_location: lexer.source_location
            )

          %Token{} = lexer ->
            Elil.Logger.error_log_and_die(
              lexer,
              "a valid identifier is expected when doing a \"let\" binding, got: :#{Atom.to_string(lexer.token)}"
            )
        end

      %Token{value: "ass"} ->
        case Lexer.shift(pid) do
          %Token{token: :ident} = lexer ->
            ident = parse_ident(pid)
            {:ok, term} = parse_params(pid)
            # hard assert for now.
            1 = length(term)

            struct!(Node,
              type: Node.Type.ass(),
              body: ident,
              params: term,
              source_location: lexer.source_location
            )

          %Token{} = lexer ->
            Elil.Logger.error_log_and_die(
              lexer,
              "a valid identifier is expected when doing a \"let\" binding, got: :#{Atom.to_string(lexer.token)}"
            )
        end

      %Token{value: "deffn"} = lexer ->
        Lexer.shift(pid)
        fn_name = parse_ident(pid)

        {:ok, fn_params} = parse_func_params(pid)

        %Token{token: :oparen} = Lexer.current(pid)
        Lexer.shift(pid)

        {:ok, body} =
          parse_scope_term_list(pid)
          |> then(
            &{elem(&1, 0),
             struct!(Node,
               type: Node.Type.fn_body(),
               params: elem(&1, 1),
               source_location: lexer.source_location
             )}
          )

        Lexer.shift(pid)

        params = [fn_params: fn_params, fn_body: body]

        struct!(Node,
          type: Node.Type.deffn(),
          body: fn_name,
          params: params,
          source_location: lexer.source_location
        )

      %Token{value: "lt"} = lexer ->
        Lexer.shift(pid)
        {:ok, params} = parse_params(pid)

        struct!(Node,
          type: Node.Type.lt(),
          body: lexer.value,
          params: params,
          source_location: lexer.source_location
        )

      %Token{value: "if"} = lexer ->
        %Token{token: :oparen} = Lexer.shift(pid)
        Lexer.shift(pid)
        {:ok, c} = parse_term(pid)
        Lexer.shift(pid)

        {:ok, t} = parse_if_branch(pid)

        e =
          case Lexer.current(pid) do
            %Token{token: :oparen} ->
              Lexer.shift(pid)

              parse_if_branch(pid)
              |> then(fn {:ok, e} -> e end)

            _ ->
              nil
          end

        # @see logging erros this just hard fails, it should probably have a nice message :)
        %Token{token: :cparen} = Lexer.current(pid)
        Lexer.shift(pid)

        struct!(Node,
          type: Node.Type.cond_if(),
          body: c,
          params: [then: t, else: e],
          source_location: lexer.source_location
        )

      %Token{} = lexer ->
        todo("unhandled keyword: \"#{lexer.value}\"")
    end
  end

  defp expect_token(%Token{} = lexer, expected_tokens)
       when is_list(expected_tokens) and length(expected_tokens) > 1 do
    case Enum.member?(expected_tokens, lexer.token) do
      true ->
        :ok

      false ->
        expected_tokens
        |> Enum.map(fn t -> "\":#{Atom.to_string(t)}\"" end)
        |> Enum.join(", ")
        |> then(
          &Elil.Logger.error_log_and_die(
            lexer,
            "expected one of [\":#{&1}\"], but got \":#{Atom.to_string(lexer.token)}\""
          )
        )

        :err
    end
  end

  defp expect_token(%Token{} = lexer, expected_token)
       when is_list(expected_token) and length(expected_token) <= 1 do
    expect_token(lexer, List.first!(expected_token))
  end

  defp expect_token(%Token{} = lexer, expected_token)
       when is_atom(expected_token) do
    case lexer.token do
      ^expected_token ->
        :ok

      # TODO: @see logging errors
      _ ->
        Elil.Logger.error_log_and_die(
          lexer,
          "expected \":#{Atom.to_string(expected_token)}\", but got \":#{Atom.to_string(lexer.token)}\""
        )

        :err
    end
  end

  defp parse_if_branch(pid) when is_pid(pid) do
    then_start = Lexer.current(pid)

    case parse_scope_term_list(pid) do
      # Allow single terms not to be wrapped in a scope.
      {:err, _msg} ->
        parse_term(pid)

      {:ok, l} ->
        {:ok,
         struct!(Node,
           type: Node.Type.scope(),
           params: l,
           source_location: then_start.source_location
         )}
    end
  end
end
