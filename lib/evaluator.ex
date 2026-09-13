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
      @compile {:inline,
                int: 0, void: 0, string: 0, bool_false: 0, bool_true: 0, func: 0, bool_type: 1}
      def int(), do: :int
      def void(), do: :void
      def string(), do: :string
      def func(), do: :func
      def bool_true(), do: :bool_true
      def bool_false(), do: :bool_false
      def bool_type(false), do: bool_false()
      def bool_type(true), do: bool_true()
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

    def new(v, :bool) do
      new(nil, Type.bool_type(v))
    end

    def new(_v, :bool_true) do
      struct!(Value, type: Type.bool_true(), value: 1)
    end

    def new(_v, :bool_false) do
      struct!(Value, type: Type.bool_false(), value: 0)
    end

    def new(v, :string) when not is_nil(v) do
      struct!(Value, type: Type.string(), value: to_string(v))
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

    def lt(%Value{type: :int} = lt, %Value{type: :int} = gt) do
      new(raw_int(lt) < raw_int(gt), :bool)
    end

    defp raw_int(%Value{type: :int, value: val} = _v) when is_binary(val) do
      String.to_integer(val, 10)
    end

    defp raw_int(%Value{type: :int, value: val} = _v) when is_integer(val) do
      val
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

    def reassign_let(pid, var_name, %Value{type: type} = value)
        when is_pid(pid) and is_binary(var_name) and type != :void do
      # TODO: @see logging errors
      # cannot assign void to anything, so we hard fail for now

      GenServer.call(pid, {:reassign_let, var_name, value})
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
    def handle_call(
          {:reassign_let, var_name, %Value{type: type} = value},
          _from,
          %Context{} = state
        )
        when type != :void and is_binary(var_name) do
      # TODO: make local variables when we introduce functions
      case do_reassign_let(var_name, state.scopes, value) do
        # scopes cannot change if the variable is undefined, so ignore them.
        {:undefined, _} ->
          {:reply, {:undefined}, state}

        {:ok, scopes} ->
          {:reply, {:ok}, struct!(state, scopes: scopes)}
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

    defp do_reassign_let(_name, [], %Value{} = _value), do: {:undefined, nil}

    defp do_reassign_let(name, [scope | rest], %Value{} = value) when is_binary(name) do
      if Map.has_key?(scope.symbols, name) do
        {:ok, [struct!(scope, symbols: Map.put(scope.symbols, name, value)) | rest]}
      else
        case do_reassign_let(name, rest, value) do
          {:ok, rest} -> {:ok, [scope | rest]}
          {:undefined, _} -> {:undefined, nil}
        end
      end
    end
  end

  defguard is_scope_type(type) when type in [:root, :scope]
  defguard is_lit(type) when type in [:dqstr, :int, :bool_true, :bool_false]

  @elil_types [:string, :int, :func, :mixed]

  defp is_builtin_type(t) when is_atom(t) do
    t in @elil_types
  end

  defp is_valid_type(t) do
    is_builtin_type(t)
  end

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

  defp eval_node(pid, %Node{type: :ass} = node) when is_pid(pid) do
    eval_ass(pid, node)
  end

  defp eval_node(pid, %Node{type: :deffn} = node) when is_pid(pid) do
    eval_deffn(pid, node)
  end

  defp eval_node(pid, %Node{type: :lt} = node) when is_pid(pid) do
    eval_bool(pid, node)
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
  defp eval_params(pid, %Node{type: type} = node) when is_pid(pid) and type in [:let, :ident] do
    node.params
    |> Enum.map(&eval_node(pid, &1))
  end

  defp eval_expr(pid, %Node{type: :ident} = node) when is_pid(pid) do
    case eval_func(pid, node.body, node.params) do
      {:err, msg} -> Elil.Logger.error_log_and_die(node, msg)
      %Value{} = value -> value
    end
  end

  defp eval_func(pid, func, args) when is_binary(func) and is_list(args) and is_pid(pid) do
    # TODO: @see logging errors the current logging just bubbles up to the calling function,
    # which doesn't take specific arguments or anything into account. Good enough
    # for now, but at a later point, I would like to have errors be more pin-pointable and direct
    case func do
      "add" ->
        Enum.map(args, fn v ->
          eval_node(pid, v)
          |> to_string()
          |> Integer.parse(10)
        end)
        |> Enum.reduce(0, fn
          {v, rem}, _acc when is_list(rem) and length(rem) > 0 ->
            {:err, "function add() expects only integers as arguments, got #{v}"}

          {v, _rem}, acc when is_integer(v) ->
            v + acc

          v, _acc ->
            {:err, "function add() expects only integers as arguments, got #{v}"}
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
            {:err, "function sub() expects only integers as arguments, got #{v}"}

          {v, _rem}, acc when is_integer(v) ->
            v + acc

          v, _acc ->
            {:err, "function sub() expects only integers as arguments, got #{v}"}
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

        %Value{type: :string} = value = eval_node(pid, arg)

        value
        |> then(& &1.value)
        |> eval()
        |> Value.new(Value.Type.void())

      _ ->
        {:err, "symbol \"#{func}\" is not a defined symbol"}
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
    Value.new(node.body, Value.Type.string())
  end

  defp eval_deffn(pid, %Node{type: :deffn} = node) when is_pid(pid) do
    # NOTE: this code looks a lot like eval_let. Especially since we use the same namespace for deffn and let
    # TODO: since we use func type for deffn, we probably need some sort of quoted thing, for when functions as first class citizens are eventually introduced

    value = Value.new(node.params, Value.Type.func())

    case Context.put_symbol(pid, node.body, value) do
      :already_exists ->
        Elil.Logger.error_log_and_die(
          node,
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
      :already_exists ->
        Elil.Logger.error_log_and_die(
          node,
          "symbol \"#{to_string(node.body)}\" has already been previously defined"
        )

      _ ->
        {:ok}
    end
  end

  defp eval_ass(pid, %Node{type: :ass} = node) when is_pid(pid) do
    # Hard assert for now. Only one value can be assigned to a variable.
    1 = length(node.params)
    [head | _] = node.params
    %Value{} = value = eval_node(pid, head)

    case Context.reassign_let(pid, node.body, value) do
      {:undefined} ->
        Elil.Logger.error_log_and_die(
          node,
          "symbol \"#{to_string(node.body)}\" is undefined. To reassign something you need to define it first, using something like the \"let\" keyword."
        )

      _ ->
        {:ok}
    end
  end

  defp eval_ident(pid, %Node{type: :ident} = node) when is_pid(pid) do
    # TODO: figure out when we need to do a function lookup vs a variable lookup
    case Context.get_symbol(pid, node) do
      {:undefined} ->
        # fallback to builtin functions for now.
        # @see logging errors Maybe this should all just be put inside the scope
        # at the beginning at some point, so we can report errors properly here
        eval_expr(pid, node)

      {:ok, %Value{type: :func} = value} ->
        {:ok, fn_params} =
          value.value
          |> Keyword.get(:fn_params)
          |> resolve_func_params()

        params = eval_params(pid, node)
        expect_all(params, Value)

        arguments =
          case validate_func_params(params, fn_params) do
            {:ok, arguments} ->
              arguments

            {:err, msg} ->
              # TODO: @see logging errors
              Elil.Logger.error_log_and_die(node, msg)
          end

        Context.push_scope(pid)

        # TODO: This is a bit scuffed. Maybe the Value should know its own name,
        # instead of just being the symbol key in the scope.
        arguments |> Enum.each(&Context.put_symbol(pid, elem(&1, 0), elem(&1, 1)))

        fn_body = Keyword.get(value.value, :fn_body)
        {:ok} = r = eval_node(pid, fn_body)

        return =
          if r !== {:ok} do
            todo("handle function returning value")
          else
            struct!(Value, type: Value.Type.void())
          end

        Context.pop_scope(pid)

        # TODO: This return might have to be assigned to something
        {:ok, return}

      # void cannot be a vairable, so hard assert for now.
      # TODO: @see logging errors we wanna either log that void is not valid and crash, or allow void as some sort of valid value.
      {:ok, %Value{type: type} = value} when type != :void ->
        value
    end
  end

  defp resolve_func_params(v, acc \\ [])

  defp resolve_func_params(v, acc) when is_list(v) and 0 === length(v) do
    {:ok, Enum.reverse(acc)}
  end

  defp resolve_func_params(v, acc) when is_list(v) do
    [head | tail] = v

    if not is_valid_type(Keyword.get(head.params, :type)) do
      Elil.Logger.error_log_and_die(head, "invalid type given for argument")
    end

    resolve_func_params(tail, [head | acc])
  end

  defp validate_func_params(parameters, arguments)
       when is_list(arguments) and is_list(parameters) and
              length(arguments) !== length(parameters) do
    {
      :err,
      # TODO: @see logging erros. The function name should be logged here. idk maybe with a format string parsed above?
      "not enough arguments passed to function. Got #{length(parameters)}, but expected #{length(arguments)}"
    }
  end

  defp validate_func_params(parameters, arguments)
       when is_list(parameters) and is_list(arguments) do
    Enum.zip([parameters, arguments])
    |> Enum.map(fn {parameter, argument} ->
      case validate_single_func_param(parameter, argument) do
        {:ok, {name, %Value{} = value}} -> {name, value}
        # TODO: @see logging errors
        {:err, msg} -> Elil.Logger.error_log_and_die(argument, msg)
      end
    end)
    |> then(&{:ok, &1})
  end

  defp validate_single_func_param(
         %Value{type: atype} = _argument,
         %Node{params: [type: ptype]} = _parameter
       )
       when is_atom(ptype) and is_atom(atype) and ptype !== atype do
    # TODO: @see logging errors The arguments here need to say which argument was wrong and stuff like that.
    {:err,
     "argument does not have the same type as the parameter needs. Got: #{Atom.to_string(atype)}, but expected #{Atom.to_string(ptype)}"}
  end

  defp validate_single_func_param(
         %Value{type: atype} = argument,
         %Node{params: [type: ptype]} = parameter
       )
       when is_atom(ptype) and is_atom(atype) do
    # TODO: this only works for literals with no parameters. Maybe not the best idea.
    {:ok, {parameter.body, struct!(Value, type: argument.type, value: argument.value)}}
  end

  defp expect_all(values, struct_type) when is_list(values) and is_atom(struct_type) do
    values
    |> Enum.each(fn
      v when is_struct(v, struct_type) -> :ok
      # TODO: @see logging errors
      _ -> Elil.Logger.error_log_and_die("idk")
    end)
  end

  defp expect_parameter_count(%Node{params: params} = node, count)
       when is_list(params) and is_integer(count) do
    if length(node.params) === count do
      {:ok}
    else
      Elil.Logger.error_log_and_die(
        node,
        "function: \"#{node.body}\" expected #{Integer.to_string(count)} amount of argumnets, but got: #{length(node.params)}"
      )
    end
  end

  defp eval_bool(pid, %Node{type: :lt} = node) do
    expect_parameter_count(node, 2)
    [lt | tail] = node.params
    [gt | _] = tail
    lt = %Value{type: :int} = eval_node(pid, lt)
    gt = %Value{type: :int} = eval_node(pid, gt)
    Value.lt(lt, gt)
  end
end
