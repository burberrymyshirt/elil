defmodule Elil.Context do
  alias Elil.Evaluator.Value
  alias Elil.Parser.Node
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
    {:ok, struct!(__MODULE__)}
  end

  @impl true
  def handle_call({:push_scope}, _from, %__MODULE__{} = state) do
    state = struct!(state, scopes: [struct!(Scope) | state.scopes])
    {:reply, {:ok}, state}
  end

  @impl true
  def handle_call({:pop_scope}, _from, %__MODULE__{} = state) do
    [_ | scopes] = state.scopes
    state = struct!(state, scopes: scopes)
    {:reply, {:ok}, state}
  end

  @impl true
  def handle_call(
        {:put_symbol, var_name, %Value{type: type} = value},
        _from,
        %__MODULE__{} = state
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
        %__MODULE__{} = state
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
  def handle_call({:get_symbol, name}, _from, %__MODULE__{} = state) do
    # TODO: make local variables when we introduce functions
    case do_get_symbol(name, state.scopes) do
      {:undefined} ->
        {:reply, {:undefined}, state}

      {:ok, %Value{} = value} ->
        {:reply, {:ok, value}, state}
    end
  end

  defp do_get_symbol(name, []) when is_binary(name), do: {:undefined}

  defp do_get_symbol(name, [scope | rest_scopes]) when is_binary(name) do
    case Map.get(scope.symbols, name) do
      nil ->
        do_get_symbol(name, rest_scopes)

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
