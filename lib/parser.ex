defmodule Elil.Parser do
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
    {:ok, result} = parse_term_list(lexer_pid)
    {:ok, %Node{type: Node.Type.root(), params: result}}
  end

  defp parse_term(pid) do
    %Lexer{token: :ident} = Lexer.current(pid)
    ident = parse_ident(pid)
    Lexer.shift(pid)
    params = parse_params(pid)
    node = struct!(%Node{}, type: Node.Type.expr(), body: ident, params: params)
    %Lexer{token: :cparen} = Lexer.current(pid)
    {:ok, node}
  end

  defp parse_term_list(pid, acc \\ []) when is_pid(pid) do
    case Lexer.current(pid) do
      nil ->
        case Lexer.shift(pid) do
          %Lexer{token: :oparen} ->
            parse_term_list(pid, acc)

          %Lexer{} = lexer ->
            Elil.Logger.error_log_and_die(
              Lexer.get_file_path(pid),
              lexer,
              "expected oparen as first token, but got: :#{Atom.to_string(lexer.token)}"
            )
        end

      %Lexer{token: :cparen} ->
        {:ok, Enum.reverse(acc)}

      %Lexer{token: :eof} ->
        {:ok, Enum.reverse(acc)}

      %Lexer{token: :oparen} ->
        case Lexer.shift(pid) do
          %Lexer{token: :ident} ->
            {:ok, term} = parse_term(pid)
            %Lexer{token: :cparen} = Lexer.current(pid)
            Lexer.shift(pid)
            parse_term_list(pid, [term | acc])

          %Lexer{token: :oparen} ->
            {:ok, list} = parse_term_list(pid)
            %Lexer{token: :cparen} = Lexer.current(pid)
            Lexer.shift(pid)
            node = struct!(%Node{}, type: Node.Type.scope(), params: list)
            parse_term_list(pid, [node | acc])
        end
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

      %Lexer{token: token} = lexer when is_lit(token) ->
        Lexer.shift(pid)
        parse_params(pid, [struct!(%Node{type: Node.Type.lit(), body: lexer.value}) | acc])

      %Lexer{token: :cparen} ->
        Enum.reverse(acc)
    end
  end
end
