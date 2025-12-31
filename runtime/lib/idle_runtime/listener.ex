defmodule IdleRuntime.Listener do
  @moduledoc """
  Unix socket listener for hook communication.

  Protocol: Length-prefixed JSON messages.
  - 4 bytes big-endian length prefix
  - JSON payload

  Request format:
    {"type": "assert" | "retract" | "query", "pattern": {...}, "body": {...}}

  Response format:
    {"type": "ok" | "error" | "assertion" | "retraction", ...}
  """

  use GenServer

  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    socket_path = Keyword.fetch!(opts, :socket_path)

    # Open Unix domain socket
    {:ok, listen_socket} = :gen_tcp.listen(0, [
      :binary,
      {:packet, 4},  # 4-byte length prefix
      {:active, false},
      {:reuseaddr, true},
      {:ip, {:local, socket_path}}
    ])

    # Start acceptor loop
    {:ok, _} = Task.start_link(fn -> accept_loop(listen_socket) end)

    Logger.info("Listener started on #{socket_path}")

    {:ok, %{socket: listen_socket, socket_path: socket_path}}
  end

  @impl true
  def terminate(_reason, state) do
    :gen_tcp.close(state.socket)
    File.rm(state.socket_path)
    :ok
  end

  defp accept_loop(listen_socket) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, client_socket} ->
        # Spawn handler for this connection
        {:ok, _} = Task.start(fn -> handle_connection(client_socket) end)
        accept_loop(listen_socket)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Logger.error("Accept error: #{inspect(reason)}")
        accept_loop(listen_socket)
    end
  end

  defp handle_connection(socket) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, data} ->
        response = process_message(data)
        :gen_tcp.send(socket, response)
        # Keep connection open for more messages
        handle_connection(socket)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Logger.warning("Connection error: #{inspect(reason)}")
        :ok
    end
  after
    :gen_tcp.close(socket)
  end

  defp process_message(data) do
    case Jason.decode(data) do
      {:ok, message} ->
        result = IdleRuntime.Protocol.handle(message)
        Jason.encode!(result)

      {:error, reason} ->
        Jason.encode!(%{
          "type" => "error",
          "error" => "invalid_json",
          "message" => inspect(reason)
        })
    end
  end
end
