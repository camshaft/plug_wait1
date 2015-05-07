defmodule Plug.Adapters.Wait1.Handler do
  @moduledoc false
  @connection Plug.Adapters.Wait1.Conn
  @fallback Plug.Adapters.Cowboy.Handler
  @already_sent {:plug_conn, :sent}

  def init({transport, :http}, req, {plug, opts, onconnection}) when transport in [:tcp, :ssl] do
    case :cowboy_req.header("upgrade", req) do
      {upgrade, _} when upgrade in ["Websocket", "websocket"] ->
        case onconnection.(req) do
          {:ok, req} ->
            case :cowboy_req.parse_header("sec-websocket-protocol", req) do
              {:ok, protocols, req} when is_list(protocols) ->
                req = select_protocol(protocols, req)
                {:upgrade, :protocol, :cowboy_websocket, req, {plug, opts}}
              {:ok, _, req} ->
                {:upgrade, :protocol, :cowboy_websocket, req, {plug, opts}}
            end
          {:halt, req} ->
            {:shutdown, req, {plug, opts, onconnection}}
        end
      _ ->
        {:upgrade, :protocol, __MODULE__, req, {transport, plug, opts}}
    end
  end

  defp select_protocol([], req) do
    req
  end
  defp select_protocol(["wait1" | rest], req) do
    select_protocol(rest, :cowboy_req.set_resp_header("sec-websocket-protocol", "wait1", req))
  end
  defp select_protocol([<<"wait1|t", token :: binary>> | rest], req) do
    headers = [{"authorization", "Bearer " <> token} | :cowboy_req.get(:headers, req)]
    select_protocol(rest, :cowboy_req.set([headers: headers], req))
  end
  defp select_protocol([<<"wait1|b", basic :: binary>> | rest], req) do
    headers = [{"authorization", "Basic " <> basic} | :cowboy_req.get(:headers, req)]
    select_protocol(rest, :cowboy_req.set([headers: headers], req))
  end
  defp select_protocol([_ | rest], req) do
    select_protocol(rest, req)
  end

  def upgrade(req, env, _, transport) do
    @fallback.upgrade(req, env, @fallback, transport)
  end

  def websocket_init(transport, req, {plug, opts}) do
    {:ok, conn, req} = @connection.init(req, transport)
    {:ok, req, {plug, opts, conn}}
  end

  def websocket_handle({:text, content}, req, state) do
    case parse(content, state) do
      {:error, _} ->
        {:reply, {:text, "[[0,\"invalid request\"]]"}, req, state}
      {:ok, _reqs} ->
        {:ok, req, state}
    end
  end
  def websocket_handle({:ping, _}, req, state) do
    {:ok, :pong, req, state}
  end
  def websocket_handle({:pong, _}, req, state) do
    {:ok, req, state}
  end
  def websocket_handle(other, req, state) do
    IO.inspect other
    {:ok, req, state}
  end

  def websocket_info({:wait1_resp, _, res}, req, state) do
    {:reply, {:text, res}, req, state}
  end
  def websocket_info({:wait1_reqs, _, hreqs}, req, state) do
    {:ok, _reqs, state} = handle(hreqs, state, [])
    {:ok, req, state}
  end
  def websocket_info({:wait1_cookie, resp_cookies}, req, {plug, opts, init}) do
    {:ok, init} = @connection.update_cookies(init, resp_cookies)
    {:ok, req, {plug, opts, init}}
  end
  def websocket_info({:plug_conn, :sent}, req, state) do
    {:ok, req, state}
  end
  def websocket_info({:DOWN, _ref, :process, _pid, :normal}, req, state) do
    {:ok, req, state}
  end
  def websocket_info(_info, req, state) do
    IO.inspect _info
    {:ok, req, state}
  end

  def websocket_terminate(_reason, _req, _state) do
    :ok
  end

  defp parse(content, state) do
    case Poison.decode(content) do
      {:ok, reqs} when is_list(reqs) ->
        handle(reqs, state, [])
      error ->
        error
    end
  end

  defp handle([], _, acc) do
    {:ok, acc}
  end
  defp handle([[id, method, path, headers] | reqs], state, acc) do
    ref = spawn_monitor(__MODULE__, :handler, [id, method, path, headers, nil, nil, state])
    handle(reqs, state, [ref | acc])
  end
  defp handle([[id, method, path, headers, qs] | reqs], state, acc) do
    ref = spawn_monitor(__MODULE__, :handler, [id, method, path, headers, qs, nil, state])
    handle(reqs, state, [ref | acc])
  end
  defp handle([[id, method, path, headers, qs, body] | reqs], state, acc) do
    ref = spawn_monitor(__MODULE__, :handler, [id, method, path, headers, qs, body, state])
    handle(reqs, state, [ref | acc])
  end
  defp handle([req | reqs], state, acc) do
    IO.inspect {:invalid, req}
    handle(reqs, state, acc)
  end

  defmodule Body do
    defstruct body: nil
  end

  def handler(id, method, [""], headers, qs, body, state) do
    handler(id, method, [], headers, body, qs, state)
  end
  def handler(id, method, path, req_headers, qs, body, {plug, opts, init} = state) do
    conn = @connection.conn(init, method, path, req_headers, qs, body)
    conn = %{adapter: {@connection, res}} = plug.call(conn, opts)
    resp_cookies = conn.resp_cookies
    if Map.size(resp_cookies) > 0 do
      send init.owner, {:wait1_cookie, resp_cookies}
    end
    res_headers = Enum.reduce(res.headers, %{}, &join_headers/2)
    response(id, res.status, res_headers, res.body, state, req_headers)
  end

  def join_headers({name, value}, acc) do
    case Map.get(acc, name) do
      nil ->
        Map.put(acc, name, value)
      values when is_list(values) ->
        Map.put(acc, name, [value | values])
      prev ->
        Map.put(acc, name, [value, prev])
    end
  end

  def response(id, status, res_headers = %{"location" => location}, _, state, req_headers) when status == 302 or status == 303 do
    parts = URI.parse(location)
    # TODO handle query string
    [_ | path] = String.split(parts.path, "/")
    handler(id, "GET", path, req_headers, parts.query, nil, state)
    invalidates(res_headers, state, req_headers)
  end
  def response(id, status, headers, body, {_, _, init} = state, req_headers) do
    res_body = %Plug.Adapters.Wait1.Handler.Body{body: body}
    out = Poison.encode!([[id, status, headers, res_body]])
    send init.owner, {:wait1_resp, id, out}
    invalidates(headers, state, req_headers)
  end

  def invalidates(%{"x-invalidates" => link}, state, req_headers) do
    link = if is_list(link), do: link, else: [link]
    Enum.map(link, &(invalidate(&1, state, req_headers)))
  end
  def invalidates(_, _, _) do
    :ok
  end

  def invalidate(path, state, req_headers) do
    case String.split(path, "?") do
      [path] ->
        handler(-1, "GET", string_to_path(path), req_headers, %{}, nil, state)
      [path, qs] ->
        handler(-1, "GET", string_to_path(path), req_headers, qs, nil, state)
    end
  end

  def string_to_path(path) when is_list(path) do
    path
  end
  def string_to_path(str) do
    parts = URI.parse(str)
    [_ | path] = String.split(parts.path, "/")
    path
  end
end

defimpl Poison.Encoder, for: Plug.Adapters.Wait1.Handler.Body do
  def encode(val, _options) do
    val.body
  end
end
