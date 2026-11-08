defmodule Elil.Parser do
  alias Elixir.String, as: EString
  alias Elixir.Integer, as: EInteger
  alias Elil.Lexer
  alias Elil.Lexer.Token
  alias Elil.Utils.SourceLocation
  # require Elil.Utils
  # import Elil.Utils

  defmodule Integer do
    @enforce_keys [:source_location, :value]
    defstruct [:value, :source_location]
  end

  defmodule Boolean do
    @enforce_keys [:source_location, :value]
    defstruct [:value, :source_location]
  end

  defmodule String do
    @enforce_keys [:source_location, :value]
    defstruct [:value, :source_location]
  end

  defmodule Scope do
    @enforce_keys [:source_location, :value]
    defstruct [:value, :source_location]
  end

  defmodule Reference do
    @enforce_keys [:source_location, :name]
    defstruct [:name, :source_location, value: nil]

    # TODO: actually use validate..
    def validate(%__MODULE__{name: n}) when is_atom(n), do: true
    def validate(%__MODULE__{}), do: false
  end

  defmodule Parameter do
    @enforce_keys [:source_location, :name, :type]
    defstruct [:name, :type, :source_location]
  end

  defmodule Condition do
    @enforce_keys [:source_location, :condition, :then]
    defstruct [:condition, :then, :source_location, otherwise: nil]
  end

  defmodule Definition do
    @types [:func, :var, :gvar, :ass, :gass]
    @enforce_keys [:source_location, :value, :name, :type]
    defstruct [:name, :type, :value, :source_location]

    # TODO: actually use validate..
    def validate(%__MODULE__{type: t}) when t in @types, do: true
    def validate(%_{}), do: false
  end

  defmodule Context do
    defstruct [
      :state,
      nested_level: 0,
      current_node: nil
    ]
  end

  defguardp is_lit(v) when v in [:dqstr, :bool_true, :bool_false, :int]

  defguardp is_keyword(t)
            when t in [
                   :let,
                   :ass,
                   :deffn,
                   :cond_if,
                   :lt,
                   :lte,
                   :gt,
                   :gte,
                   :eq,
                   :negate
                 ]

  defguardp is_beginning_of_statement_or_expression(t)
            when t === :ident or is_keyword(t)

  def parse(lexer_pid) when is_pid(lexer_pid) do
    {:ok, list} = parse_root_term_list(lexer_pid)

    {:ok,
     %Scope{
       value: list,
       source_location:
         struct!(SourceLocation,
           row: 0,
           col: 0,
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
        # Root scope doesn't end in cparen, always :eof.
        # Lexer is very broken if we don't hit it...
        {:ok, Enum.reverse(acc)}

      %Token{token: :oparen} ->
        case Lexer.shift(pid) do
          # nested scopes
          %Token{token: :oparen} = lexer ->
            {:ok, list} = parse_scope_term_list(pid)

            node =
              struct!(Scope,
                value: list,
                source_location: lexer.source_location
              )

            parse_root_term_list(pid, [node | acc])

          # standalone terms
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
          # standalone terms
          %Token{token: token}
          when is_beginning_of_statement_or_expression(token) ->
            {:ok, term} = parse_term(pid)
            parse_scope_term_list(pid, [term | acc])

          # nested scopes
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
        # we can't validate the length before hitting the evaluator, as the
        # parser doesn't know about the function being defined
        {:ok, params} =
          case parse_params(pid) do
            {:ok, params} ->
              {:ok, params}

            # TODO: make this formatting thing a part of the Logger module
            {:err, msg} ->
              Elil.Logger.error_log_and_die(
                lexer.source_location,
                EString.replace(msg, "#(func_name)", to_string(lexer.value))
              )
          end

        node =
          %Reference{
            name: ident,
            value: params,
            source_location: lexer.source_location
          }

        {:ok, node}

      %Token{token: :let} ->
        case Lexer.shift(pid) do
          %Token{token: :ident} = lexer ->
            ident = parse_ident(pid)
            {:ok, term} = parse_params(pid, 1)
            # validated through parse_params, but this is fine I guess.
            1 = length(term)

            {:ok,
             %Definition{
               type: :var,
               name: ident,
               value: term,
               source_location: lexer.source_location
             }}

          %Token{} = lexer ->
            Elil.Logger.error_log_and_die(
              lexer,
              "a valid identifier is expected when doing a \"let\" binding, got: :#{Atom.to_string(lexer.token)}"
            )
        end

      %Token{token: :ass} ->
        case Lexer.shift(pid) do
          %Token{token: :ident} = lexer ->
            ident = parse_ident(pid)
            {:ok, term} = parse_params(pid, 1)
            # validated through parse_params, but this is fine I guess.
            1 = length(term)

            {:ok,
             struct!(Definition,
               type: :ass,
               name: ident,
               value: term,
               source_location: lexer.source_location
             )}

          %Token{} = lexer ->
            Elil.Logger.error_log_and_die(
              lexer,
              "a valid identifier is expected when doing a \"let\" binding, got: :#{Atom.to_string(lexer.token)}"
            )
        end

      %Token{token: :deffn} = lexer ->
        Lexer.shift(pid)
        fn_name = parse_ident(pid)

        {:ok, fn_params} = parse_func_params(pid)

        %Token{token: :oparen} = Lexer.current(pid)
        Lexer.shift(pid)

        {:ok, body} =
          parse_scope_term_list(pid)
          |> then(
            &{elem(&1, 0),
             struct!(Scope,
               value: elem(&1, 1),
               source_location: lexer.source_location
             )}
          )

        Lexer.shift(pid)

        params = [fn_params: fn_params, fn_body: body]

        {:ok,
         struct!(Definition,
           type: :func,
           name: fn_name,
           value: params,
           source_location: lexer.source_location
         )}

      # TODO: fix all of these static boolean definitions with global guards, so
      #  they don't have to be duplicated...
      %Token{token: :lt} = lexer ->
        Lexer.shift(pid)

        # could pass 2 to parse_params, but I feel like it's fine to let this be variadic.
        # As long as the evaluator can handle it.
        {:ok, params} = parse_params(pid)

        {:ok,
         struct!(Reference,
           name: lexer.token,
           value: params,
           source_location: lexer.source_location
         )}
      %Token{token: :lte} = lexer ->
        Lexer.shift(pid)

        # could pass 2 to parse_params, but I feel like it's fine to let this be variadic.
        # As long as the evaluator can handle it.
        {:ok, params} = parse_params(pid)

        {:ok,
         struct!(Reference,
           name: lexer.token,
           value: params,
           source_location: lexer.source_location
         )}
      %Token{token: :gte} = lexer ->
        Lexer.shift(pid)

        # could pass 2 to parse_params, but I feel like it's fine to let this be variadic.
        # As long as the evaluator can handle it.
        {:ok, params} = parse_params(pid)

        {:ok,
         struct!(Reference,
           name: lexer.token,
           value: params,
           source_location: lexer.source_location
         )}
      %Token{token: :gt} = lexer ->
        Lexer.shift(pid)

        # could pass 2 to parse_params, but I feel like it's fine to let this be variadic.
        # As long as the evaluator can handle it.
        {:ok, params} = parse_params(pid)

        {:ok,
         struct!(Reference,
           name: lexer.token,
           value: params,
           source_location: lexer.source_location
         )}
      %Token{token: :eq} = lexer ->
        Lexer.shift(pid)

        # could pass 2 to parse_params, but I feel like it's fine to let this be variadic.
        # As long as the evaluator can handle it.
        {:ok, params} = parse_params(pid)

        {:ok,
         struct!(Reference,
           name: lexer.token,
           value: params,
           source_location: lexer.source_location
         )}

      %Token{token: :cond_if} = lexer ->
        %Token{token: :oparen} = Lexer.shift(pid)
        Lexer.shift(pid)
        {:ok, c} = parse_term(pid)
        Lexer.shift(pid)

        {:ok, t} = parse_if_branch(pid)

        o =
          case Lexer.current(pid) do
            %Token{token: :oparen} ->
              Lexer.shift(pid)

              parse_if_branch(pid)
              |> then(fn {:ok, o} -> o end)

            _ ->
              nil
          end

        # @see logging erros this just hard fails, it should probably have a nice message :)
        %Token{token: :cparen} = Lexer.current(pid)
        Lexer.shift(pid)

        {:ok,
         struct!(Condition,
           condition: c,
           then: t,
           otherwise: o,
           source_location: lexer.source_location
         )}

      %Token{token: t} when is_lit(t) ->
        {:ok, lit} = parse_lit(pid)

        # parse_lit can't shift more than it already is, cause then we will end up skipping tokens.
        Lexer.shift(pid)

        {:ok, lit}

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

  defp parse_params(pid, len \\ :unlimited) when is_pid(pid) do
    do_parse_params(pid, len)
  end

  defp do_parse_params(pid, expected_len, actual_len \\ 0, acc \\ [])
       when is_pid(pid) and
              (is_integer(expected_len) or expected_len === :unlimited) and
              is_list(acc) and is_integer(actual_len) do
    case Lexer.current(pid) do
      %Token{token: :oparen} ->
        Lexer.shift(pid)
        {:ok, term} = parse_term(pid)
        do_parse_params(pid, expected_len, actual_len + 1, [term | acc])

      %Token{token: t} when is_lit(t) ->
        {:ok, lit} = parse_lit(pid)
        do_parse_params(pid, expected_len, actual_len + 1, [lit | acc])

      # Identifier is used as an argument to e.g. a function.
      %Token{token: :ident} = lexer ->
        node =
          struct!(Reference,
            name: parse_ident(pid),
            source_location: lexer.source_location
          )

        do_parse_params(pid, expected_len, actual_len + 1, [node | acc])

      %Token{token: :cparen} = _lexer ->
        Lexer.shift(pid)

        # This is so ass ...
        if expected_len !== :unlimited do
          if expected_len !== actual_len do
            msg =
              case expected_len > actual_len do
                true ->
                  "Too many arguments passed to function: \"#(func_name)\". Expected \"#{to_string(expected_len)}\", but got \"#{to_string(actual_len)}\""

                false ->
                  "Too few arguments passed to function: \"#(func_name)\". Expected \"#{to_string(expected_len)}\", but got \"#{to_string(actual_len)}\""
              end

            {:err, msg}
          else
            {:ok, Enum.reverse(acc)}
          end
        else
          {:ok, Enum.reverse(acc)}
        end
    end
  end

  defp parse_lit(pid) when is_pid(pid) do
    case Lexer.current(pid) do
      %Token{token: :int} = lexer ->
        Lexer.shift(pid)

        # defaults to base 10 for now.
        {v, _rest} = EInteger.parse(lexer.value)

        {:ok,
         %Integer{
           source_location: lexer.source_location,
           value: v
         }}

      %Token{token: t} = lexer when t in [:bool_false, :bool_true] ->
        Lexer.shift(pid)

        v =
          if t === :bool_true do
            true
          else
            false
          end

        {:ok,
         %Boolean{
           source_location: lexer.source_location,
           value: v
         }}

      %Token{token: :dqstr} = lexer ->
        Lexer.shift(pid)

        {:ok,
         %String{
           source_location: lexer.source_location,
           # Raw string for now
           value: lexer.value
         }}

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

      %Token{} = lexer ->
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

              struct!(Parameter,
                type: EString.to_atom(type_ident),
                name: ident,
                source_location: type.source_location
              )

            # validated by previous expect
            _ ->
              struct!(Parameter,
                type: :mixed,
                name: ident,
                source_location: current.source_location
              )
          end

        do_parse_func_params(pid, [node | acc])
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
         %Scope{
           value: l,
           source_location: then_start.source_location
         }}
    end
  end
end
