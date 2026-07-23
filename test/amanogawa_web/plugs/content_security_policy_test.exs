defmodule AmanogawaWeb.Plugs.ContentSecurityPolicyTest do
  use AmanogawaWeb.ConnCase, async: true

  alias AmanogawaWeb.Plugs.ContentSecurityPolicy

  defmodule RemoteEndpoint do
    @moduledoc false
    def struct_url, do: %URI{scheme: "https", host: "exemple.test", port: 443}
  end

  defp csp_header(conn) do
    assert [csp] = get_resp_header(conn, "content-security-policy")
    csp
  end

  defp directives(csp) do
    csp
    |> String.split("; ")
    |> Map.new(fn directive ->
      [name | sources] = String.split(directive, " ")
      {name, sources}
    end)
  end

  describe "call/2 on the browser pipeline" do
    test "sets every expected directive on GET /", %{conn: conn} do
      csp = conn |> get(~p"/") |> csp_header()
      parsed = directives(csp)

      assert parsed["default-src"] == ["'self'"]
      assert parsed["script-src"] == ["'self'"]
      assert parsed["style-src"] == ["'self'"]
      assert parsed["img-src"] == ["'self'", "data:", "blob:"]
      assert parsed["font-src"] == ["'self'"]
      assert parsed["worker-src"] == ["blob:"]
      assert parsed["child-src"] == ["blob:"]
      assert parsed["object-src"] == ["'none'"]
      assert parsed["manifest-src"] == ["'self'"]
      assert parsed["frame-ancestors"] == ["'none'"]
      assert parsed["base-uri"] == ["'self'"]
      assert parsed["form-action"] == ["'self'"]
    end

    test "connect-src holds 'self', the websocket origin, and the tiles origin",
         %{conn: conn} do
      csp = conn |> get(~p"/") |> csp_header()
      %URI{host: host, port: port} = AmanogawaWeb.Endpoint.struct_url()

      assert directives(csp)["connect-src"] == [
               "'self'",
               "ws://#{host}:#{port}",
               ContentSecurityPolicy.tiles_origin()
             ]
    end

    test "never allows unsafe sources nor unexpected third-party hosts", %{conn: conn} do
      csp = conn |> get(~p"/") |> csp_header()

      refute csp =~ "unsafe-inline"
      refute csp =~ "unsafe-eval"

      remote_sources =
        csp
        |> directives()
        |> Map.values()
        |> List.flatten()
        |> Enum.filter(&String.contains?(&1, "://"))

      %URI{host: host, port: port} = AmanogawaWeb.Endpoint.struct_url()

      allowed = [
        "ws://#{host}:#{port}",
        ContentSecurityPolicy.tiles_origin()
      ]

      assert Enum.sort(Enum.uniq(remote_sources)) == Enum.sort(allowed)
    end
  end

  describe "call/2 websocket origin derivation" do
    test "builds a wss origin without port from an https endpoint config" do
      conn =
        :get
        |> build_conn("/")
        |> ContentSecurityPolicy.call(endpoint: RemoteEndpoint)

      csp = csp_header(conn)

      assert csp =~ "wss://exemple.test"
      refute csp =~ "wss://exemple.test:443"
      refute csp =~ "ws://exemple.test"
    end

    test "omits the default port from a plain http endpoint config" do
      defmodule PlainHttpEndpoint do
        @moduledoc false
        def struct_url, do: %URI{scheme: "http", host: "exemple.test", port: 80}
      end

      conn =
        :get
        |> build_conn("/")
        |> ContentSecurityPolicy.call(endpoint: PlainHttpEndpoint)

      csp = csp_header(conn)

      assert csp =~ "ws://exemple.test"
      refute csp =~ "ws://exemple.test:80"
    end

    test "keeps a non-default port in the ws origin" do
      defmodule DevLikeEndpoint do
        @moduledoc false
        def struct_url, do: %URI{scheme: "http", host: "localhost", port: 4000}
      end

      conn =
        :get
        |> build_conn("/")
        |> ContentSecurityPolicy.call(endpoint: DevLikeEndpoint)

      assert csp_header(conn) =~ "ws://localhost:4000"
    end
  end
end
