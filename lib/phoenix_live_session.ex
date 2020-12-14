# Copyright 2013 Plataformatec.
# Copyright 2020 Pentacent.
#
# You may find a copy of the original file here:
# https://github.com/elixir-plug/plug/blob/ed0541110749531b1fd89cd2fac102ccef4041dc/lib/plug/session/ets.ex

# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0

defmodule PhoenixLiveSession do
  @moduledoc """
  Store for `Plug.Sessions` with PubSub features for `Phoenix.LiveView`


  ## Setup

  Use this in your Endpoint module when defining options for
  Plug.Sessions like so:

      # lib/my_app_web/endpoint.ex
      @session_options [
          store: PhoenixLiveSession,
          pub_sub: MyApp.PubSub,
          signing_salt: "your-salt",
      ]

  ## Usage in Phoenix Controllers
  You don’t need to do anything special to use PhoenixLiveSession in regular
  Phoenix controllers.
  Your sessions will continue to work the same as with other stores.

  ## Usage in LiveViews
  Use `maybe_subscribe/2` in your `mount/3` function to subscribe to
  LiveSession updates.
  Only sockets with `connected? == true` are subscribed by `maybe_subscribe/2`.

  Once you’ve subscribed to a LiveSession, you can handle session
  updates with `handle_info/2` and push session updates with `put_session/3`.

  ### Example

      def mount(_params, session, socket) do
        socket = socket
        |> PhoenixLiveSession.maybe_subscribe(session)
        |> put_session_assigns(session)

        {:ok, socket}
      end

      def handle_info({:live_session_updated, session}, socket) do
        {:noreply, put_session_assigns(socket, session)}
      end

      def handle_event("add_to_cart", %{"product_id" => product_id}, socket) do
        updated_cart = [product_id | socket.assigns.cart]
        PhoenixLiveSession.put_session(socket, "cart", updated_cart)

        {:noreply, socket}
      end

      defp put_sesion_assigns(socket, session) do
        socket
        |> assign(:shopping_cart, Map.get(session, "shopping_cart", []))
      end

  ## Options
    * `:pub_sub` - Required.- Module for handling PubSub (e.g. `MyApp.PubSub`).
    * `:table` - ETS table name. Defaults to `:phoenix_live_sessions`
    * `:lifetime` - Lifetime (in ms) of sessions before they are cleared.
       Reads and writes refresh session lifetime. Defaults to two days.
    * `clean_interval` - Interval (in ms) after which expired PhoenixLiveSession
      are cleared. Defaulst to 60 seconds.

  ## Caveats
  Since sessions are stored in memory, they will be lost when restarting
  your server and are not shared between servers in multi-node setups.
  """

  alias Phoenix.PubSub

  @behaviour Plug.Session.Store

  @default_table :phoenix_live_sessions
  @default_lifetime 48 * 60 * 60_000
  @default_clean_interval 60_000
  @max_tries 100

  #
  # Implementation of the Plug.Session.Store behaviour
  #

  def init(opts) do
    opts
    |> put_defaults()
  end

  def get(_conn, sid, opts) do
    table = Keyword.fetch!(opts, :table)

    maybe_clean(opts)

    case :ets.lookup(table, sid) do
      [{^sid, data, _expires_at}] ->
        :ets.update_element(table, sid, {3, expires_at(opts)})
        {sid, put_meta(data, sid, opts)}

      [] ->
        {nil, %{}}
    end
  end

  defp clean(table, opts) do
    lifetime = Keyword.fetch!(opts, :lifetime)
    now = DateTime.utc_now()

    cutoff =
      now
      |> DateTime.add(-1 * lifetime, :millisecond)
      |> DateTime.to_unix()

    :ets.select_delete(table, [{{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
    :ets.insert(table, {"last_clean", nil, DateTime.to_unix(now)})
  end

  def put(_conn, nil, data, opts) do
    put_new(data, opts)
  end

  def put(_conn, sid, data, opts) do
    table = Keyword.fetch!(opts, :table)
    :ets.insert(table, {sid, data, expires_at(opts)})
    broadcast_update(sid, data, opts)
    sid
  end

  def delete(_conn, sid, opts) do
    table = Keyword.fetch!(opts, :table)
    broadcast_update(sid, %{}, opts)
    :ets.delete(table, sid)
    :ok
  end

  defp put_new(data, opts, counter \\ 0)
       when counter < @max_tries do
    table = Keyword.fetch!(opts, :table)
    sid = Base.encode64(:crypto.strong_rand_bytes(96))

    if :ets.insert_new(table, {sid, data, expires_at(opts)}) do
      broadcast_update(sid, data, opts)
      sid
    else
      put_new(data, opts, counter + 1)
    end
  end

  defp put_in(sid, key, value, opts) do
    table = Keyword.fetch!(opts, :table)

    case :ets.lookup(table, sid) do
      [{^sid, data, _expires_at}] ->
        updated_data = Map.put(data, key, value)
        :ets.update_element(table, sid, {2, updated_data})
        :ets.update_element(table, sid, {3, expires_at(opts)})
        broadcast_update(sid, updated_data, opts)
        sid

      [] ->
        put(nil, sid, %{key => value}, opts)
    end
  end

  defp put_defaults(opts) do
    opts
    |> Keyword.put_new(:table, @default_table)
    |> Keyword.put_new(:lifetime, @default_lifetime)
    |> Keyword.put_new(:clean_interval, @default_clean_interval)
  end

  defp put_meta(data, sid, opts) do
    data
    |> Map.put(:__sid__, sid)
    |> Map.put(:__opts__, opts)
  end

  defp maybe_clean(opts) do
    table = Keyword.fetch!(opts, :table)
    clean_interval = Keyword.fetch!(opts, :clean_interval)
    latest_possible_clean = DateTime.utc_now() |> DateTime.add(-1 * clean_interval, :millisecond)

    case :ets.lookup(table, "last_clean") do
      [{"last_clean", _, last_clean}] ->
        if latest_possible_clean > last_clean do
          clean(table, opts)
        end

      [] ->
        clean(table, opts)
    end
  end

  defp expires_at(opts) do
    lifetime = Keyword.fetch!(opts, :lifetime)

    DateTime.utc_now()
    |> DateTime.add(lifetime, :millisecond)
    |> DateTime.to_unix()
  end

  defp broadcast_update(sid, data, opts) do
    pub_sub = Keyword.fetch!(opts, :pub_sub)
    channel = "live_session:#{sid}"
    PubSub.broadcast(pub_sub, channel, {:live_session_updated, put_meta(data, sid, opts)})
  end

  #
  # PhoenixLiveSession-specific functions
  #

  @doc """
  Subscribes connected LiveView socket to LiveSession.

  Call this function in `mount/3`.
  """
  @spec maybe_subscribe(Phoenix.LiveView.Socket.t(), Plug.Session.Store.session()) ::
          Phoenix.LiveView.Socket.t()
  def maybe_subscribe(%{connected?: true} = socket, %{__sid__: sid, __opts__: opts}) do
    pub_sub = Keyword.fetch!(opts, :pub_sub)
    channel = "live_session:#{sid}"
    PubSub.subscribe(pub_sub, channel)

    socket
    |> Phoenix.LiveView.assign(:__live_session_id__, sid)
    |> Phoenix.LiveView.assign(:__live_session_opts__, opts)
  end

  def maybe_subscribe(socket, _) do
    socket
  end

  @doc """
  Use like `Plug.Conn.put_session/3` but on a LiveView socket previously
  subscribed to PhoenixLiveSession with `maybe_subscribe/2`.
  """
  @spec put_session(Phoenix.LiveView.Socket.t(), String.t() | atom(), term()) ::
          Phoenix.LiveView.Socket.t()
  def put_session(socket, key, value) do
    sid = socket.assigns.__live_session_id__
    opts = socket.assigns.__live_session_opts__
    put_in(sid, to_string(key), value, opts)

    socket
  end
end