defmodule Elil.Evaluator do
  require Elil.Utils
  import Elil.Utils
  alias Elil.Lexer, as: Lexer
  alias Elil.Parser.Node, as: Node

  defmodule Value do
    @enforce_keys [:type]
    defstruct [
      :type,
      :value
    ]

    defmodule Type do
      @compile {:inline, int: 0, void: 0, str: 0, bool_false: 0, bool_true: 0, func: 0}
      def int(), do: :int
      def void(), do: :void
      def str(), do: :str
      def func(), do: :func
      def bool_true(), do: :bool_true
      def bool_false(), do: :bool_false
    end

    defimpl String.Chars, for: __MODULE__ do
      def to_string(%Value{type: :void}) do
        ""
      end

      def to_string(%Value{} = value) do
        Kernel.to_string(value.value)
      end
    end

    def new(value, wanted_type)

    def new(_v, :void) do
      struct!(Value, type: Type.void())
    end

    def new(_v, :bool_true) do
      struct!(Value, type: Type.bool_true(), value: 1)
    end

    def new(_v, :bool_false) do
      struct!(Value, type: Type.bool_false(), value: 0)
    end

    def new(v, :str) when not is_nil(v) do
      struct!(Value, type: Type.str(), value: to_string(v))
    end

    def new(v, :func) when not is_nil(v) when is_list(v) do
      # Assert v is a list for now, as that is how it is parsed.
      struct!(Value, type: Type.func(), value: v)
    end

    def new(v, :int) when not is_nil(v) do
      v =
        case v do
          v when is_integer(v) -> v
          # TODO: handle more than just base 10
          v when is_binary(v) -> Integer.parse(v, 10) |> elem(0)
          # TODO: handle more than just base 10
          v when is_list(v) -> Integer.parse(List.to_string(v), 10) |> elem(0)
          # @see logging errors
          v -> Elil.Logger.error_log_and_die("unable to parse value \"#{v}\" to an integer")
        end

      struct!(Value, type: Type.int(), value: v)
    end
  end

  defmodule Context do
    use GenServer

    defmodule Scope do
      defstruct symbols: %{}
    end

    defstruct scopes: []

    def push_scope(pid), do: GenServer.call(pid, {:push_scope})

    def pop_scope(pid), do: GenServer.call(pid, {:pop_scope})

    def put_symbol(pid, var_name, %Value{type: type} = value)
        when is_pid(pid) and is_binary(var_name) and type != :void do
      # TODO: @see logging errors
      # cannot assign void to anything, so we hard fail for now

      GenServer.call(pid, {:put_symbol, var_name, value})
    end

    def get_symbol(pid, %Node{type: :ident} = node) when is_pid(pid) do
      get_symbol(pid, node.body)
    end

    def get_symbol(pid, var_name) when is_pid(pid) when is_pid(var_name) do
      GenServer.call(pid, {:get_symbol, var_name})
    end

    @impl true
    def init(_initial) do
      {:ok, struct!(Context)}
    end

    @impl true
    def handle_call({:push_scope}, _from, %Context{} = state) do
      state = struct!(state, scopes: [struct!(Scope) | state.scopes])
      {:reply, {:ok}, state}
    end

    @impl true
    def handle_call({:pop_scope}, _from, %Context{} = state) do
      [_ | scopes] = state.scopes
      state = struct!(state, scopes: scopes)
      {:reply, {:ok}, state}
    end

    @impl true
    def handle_call(
          {:put_symbol, var_name, %Value{type: type} = value},
          _from,
          %Context{} = state
        )
        when type != :void and is_binary(var_name) do
      # TODO: make local variables when we introduce functions
      [scope | rest_scopes] = state.scopes

      case Map.has_key?(scope.symbols, var_name) do
        true ->
          {:reply, :already_exists, state}

        false ->
          # use the variable name as the key
          symbols = Map.put_new(scope.symbols, var_name, value)
          scope = struct!(scope, symbols: symbols)
          {:reply, :ok, struct!(state, scopes: [scope | rest_scopes])}
      end
    end

    @impl true
    def handle_call({:get_symbol, name}, _from, %Context{} = state) do
      # TODO: make local variables when we introduce functions
      case do_get_symbol(name, state.scopes) do
        {:undefined} ->
          {:reply, {:undefined}, state}

        {:ok, %Value{} = value} ->
          {:reply, {:ok, value}, state}
      end
    end

    defp do_get_symbol(name, scopes) when is_binary(name) and is_list(scopes) do
      [scope | rest_scopes] = scopes

      case Map.get(scope.symbols, name) do
        nil ->
          case 0 === length(rest_scopes) do
            true -> {:undefined}
            false -> do_get_symbol(name, rest_scopes)
          end

        %Value{} = value ->
          {:ok, value}
      end
    end
  end

  defguard is_scope_type(type) when type in [:root, :scope]
  defguard is_lit(type) when type in [:dqstr, :int, :bool_true, :bool_false]

  def eval(file) do
    # TODO: error handling
    case File.exists?(file) do
      true ->
        {:ok, fd} = File.open(file, [:utf8, :read_ahead])
        eval(fd, file)

      false ->
        eval(to_string(file), "eval()")
    end
  end

  def eval(file, file_path) when is_pid(file) or is_atom(file) do
    # WANT: we just assume file is a valid atom or pid, so add validate_file or something
    IO.read(file, :eof) |> eval(file_path)
  end

  def eval(file, file_path) when is_binary(file) do
    if Elil.Cmd.get_option_bool("print_file_path") do
      IO.puts("Evaluating file: " <> file_path)
    end

    if Elil.Cmd.get_option_bool("print_lexer") do
      Lexer.lex_entire_file(file, file_path, &IO.inspect(&1))
      :ok
    else
      {:ok, lexer_pid} = GenServer.start_link(Lexer, {file_path, file}, hibernate_after: 100)
      {:ok, root_node} = Elil.Parser.parse(lexer_pid)
      GenServer.stop(lexer_pid)
      %Node{type: :root} = root_node

      if Elil.Cmd.get_option_bool("print_ast") do
        IO.inspect(root_node)
      else
        {:ok, context_pid} = GenServer.start_link(Context, [])

        # TODO: if we bubble errors up to the surface through returns, we can handle errors properly here.
        #  I don't really wanna use exceptions. I feel like they might be a crutch for a poor recursive design.
        #  Although that might be wrong and exceptions are just the way to go. Who knows.

        do_eval(context_pid, root_node)

        GenServer.stop(context_pid)
      end

      :ok
    end
  end

  defp do_eval(pid, %Node{type: :root} = node) when is_pid(pid) do
    eval_node(pid, node)
  end

  defp eval_node(pid, %Node{type: :root, body: nil} = node) when is_pid(pid) do
    {:ok} = Context.push_scope(pid)
    eval_params(pid, node)
    {:ok} = Context.pop_scope(pid)
  end

  defp eval_node(pid, %Node{type: :scope, body: nil} = node) when is_pid(pid) do
    # TODO: when calling from a function, this should behave a bit differently,
    # as we need to push the functions arguments into the new scope as well.
    {:ok} = Context.push_scope(pid)
    eval_params(pid, node)
    {:ok} = Context.pop_scope(pid)
  end

  defp eval_node(pid, %Node{type: type} = node) when is_pid(pid) and is_lit(type) do
    eval_lit(pid, node)
  end

  defp eval_node(pid, %Node{type: :let} = node) when is_pid(pid) do
    eval_let(pid, node)
  end

  defp eval_node(pid, %Node{type: :deffn} = node) when is_pid(pid) do
    eval_deffn(pid, node)
  end

  # an ident from the parser is expected to be a name of a variable or function.
  defp eval_node(pid, %Node{type: :ident} = node) when is_pid(pid) do
    eval_ident(pid, node)
  end

  # an ident from the parser is expected to be a name of a variable or function.
  defp eval_node(pid, %Node{type: :cond_if} = node) when is_pid(pid) do
    %Value{} = evaled_cond = eval_node(pid, node.body)

    case evaled_cond.type do
      t when t === :bool_true ->
        Keyword.get(node.params, :then)
        |> then(&eval_node(pid, &1))

      t when t === :bool_false ->
        then = Keyword.get(node.params, :else)

        if is_nil(then) do
          struct!(Value, type: Value.Type.void())
        else
          eval_node(pid, then)
        end

      a when is_atom(a) ->
        # @see logging erros
        Elil.Logger.error_log_and_die(
          "expected boolean when calling if-statement. Got type: \":#{Atom.to_string(a)}\""
        )
    end
  end

  defp eval_params(pid, %Node{type: type, body: nil} = node)
       when is_pid(pid) and is_scope_type(type) do
    node.params
    |> Enum.map(&eval_node(pid, &1))
  end

  # TODO: could be merged with the eval_params/2 above, idk if it is actually important that the body is nil.
  #  I just wanna assert as much as possible right now. I don't know if we need named scopes in the future,
  #  but in that case I would like to keep the assert for now so I know where refactoring is needed.
  defp eval_params(pid, %Node{type: :let} = node) when is_pid(pid) do
    node.params
    |> Enum.map(&eval_node(pid, &1))
  end

  defp eval_expr(pid, %Node{type: :ident} = node) when is_pid(pid) do
    eval_func(pid, node.body, node.params)
  end

  defp eval_func(pid, func, args) when is_binary(func) and is_list(args) and is_pid(pid) do
    # TODO: add meta data from parser to report arity/variadic parameters
    #  Right now we just ignore parameters when there are more than the function needs
    case func do
      "add" ->
        Enum.map(args, fn v ->
          eval_node(pid, v)
          |> to_string()
          |> Integer.parse(10)
        end)
        |> Enum.reduce(0, fn
          {v, rem}, _acc when is_list(rem) and length(rem) > 0 ->
            Elil.Logger.error_log_and_die(
              "function add() expects only integers as arguments, got #{v}"
            )

          {v, _rem}, acc when is_integer(v) ->
            v + acc

          v, _acc ->
            Elil.Logger.error_log_and_die(
              "function add() expects only integers as arguments, got #{v}"
            )
        end)
        |> Value.new(Value.Type.int())

      "sub" ->
        Enum.map(args, fn
          v ->
            eval_node(pid, v)
            |> to_string()
            |> Integer.parse(10)
        end)
        |> Enum.reduce(0, fn
          {v, rem}, _acc when is_list(rem) and length(rem) > 0 ->
            Elil.Logger.error_log_and_die(
              "function sub() expects only integers as arguments, got #{v}"
            )

          {v, _rem}, acc when is_integer(v) ->
            v + acc

          v, _acc ->
            Elil.Logger.error_log_and_die(
              "function sub() expects only integers as arguments, got #{v}"
            )
        end)
        |> Value.new(Value.Type.int())

      "echo" ->
        Enum.map(args, &eval_node(pid, &1))
        |> Enum.map(&to_string/1)
        |> Enum.map(&IO.write/1)
        |> Value.new(Value.Type.void())

      "eval" ->
        # TODO: make it fail if more are given or something.
        [arg | _] = args

        %Value{type: :str} = value = eval_node(pid, arg)

        value
        |> then(& &1.value)
        |> eval()
        |> Value.new(Value.Type.void())

      # TODO: add meta data from parser, so we can report line numbers
      #  @see logging errors in todo.txt
      _ ->
        Elil.Logger.error_log_and_die(
          "symbol \"#{func}\" is not defined as either a function or variable"
        )
    end
  end

  defp eval_lit(pid, %Node{type: :bool_true} = node) when is_pid(pid) do
    Value.new(node.body, Value.Type.bool_true())
  end

  defp eval_lit(pid, %Node{type: :bool_false} = node) when is_pid(pid) do
    Value.new(node.body, Value.Type.bool_false())
  end

  defp eval_lit(pid, %Node{type: :int} = node) when is_pid(pid) do
    Value.new(node.body, Value.Type.int())
  end

  defp eval_lit(pid, %Node{type: :dqstr} = node) when is_pid(pid) do
    # TODO: string interpolating
    Value.new(node.body, Value.Type.str())
  end

  defp eval_deffn(pid, %Node{type: :deffn} = node) when is_pid(pid) do
    # NOTE: this code looks a lot like eval_let. Especially since we use the same namespace for deffn and let
    # TODO: since we use func type for deffn, we probably need some sort of quoted thing, for when functions as first class citizens are eventually introduced

    value = Value.new(node.params, Value.Type.func())

    case Context.put_symbol(pid, node.body, value) do
      {:already_exists} ->
        # TODO: add meta data from parser, so we can report line numbers
        #  @see logging errors in todo.txt
        Elil.Logger.error_log_and_die(
          "symbol \"#{to_string(node.body)}\" has already been previously defined"
        )

      _ ->
        {:ok}
    end
  end

  defp eval_let(pid, %Node{type: :let} = node) when is_pid(pid) do
    # Hard assert for now. Only one value can be assigned to a variable.
    1 = length(node.params)
    [head | _] = node.params
    %Value{} = value = eval_node(pid, head)

    case Context.put_symbol(pid, node.body, value) do
      {:already_exists} ->
        # TODO: add meta data from parser, so we can report line numbers
        #  @see logging errors in todo.txt
        Elil.Logger.error_log_and_die(
          "symbol \"#{to_string(node.body)}\" has already been previously defined"
        )

      _ ->
        {:ok}
    end
  end

  defp eval_ident(pid, %Node{type: :ident} = node) when is_pid(pid) do
    # TODO: figure out when we need to do a function lookup vs a variable lookup
    case Context.get_symbol(pid, node) do
      {:undefined} ->
        eval_expr(pid, node)

      # TODO: add meta data from parser, so we can report line numbers
      #  @see logging errors in todo.txt
      # Elil.Logger.error_log_and_die("variable \"#{to_string(node.body)}\" is undefined")

      {:ok, %Value{type: :func} = value} ->
        fn_args = Keyword.get(value.value, :fn_args)
        if length(node.params) > 0 or length(fn_args) > 0, do: todo("handle function arguments")
        _fn_args = resolve_func_args(fn_args)

        fn_body = Keyword.get(value.value, :fn_body)
        {:ok} = r = eval_node(pid, fn_body)

        return =
          if r !== {:ok} do
            todo("handle function returning value")
          else
            struct!(Value, type: Value.Type.void())
          end

        # TODO: This return might have to be assigned to something
        {:ok, return}

      # void cannot be a vairable, so hard assert for now.
      # TODO: @see logging errors we wanna either log that void is not valid and crash, or allow void as some sort of valid value.
      {:ok, %Value{type: type} = value} when type != :void ->
        value
    end
  end

  defp resolve_func_args(v) do
    todo("resolve_func_args")
    v
  end
end
