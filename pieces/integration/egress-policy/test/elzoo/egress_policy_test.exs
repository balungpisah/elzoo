# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.EgressPolicyTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Elzoo.EgressPolicy

  @host "api.example.com"
  @url "https://api.example.com/v1?q=1"
  @invalid "invalid Elzoo.EgressPolicy options"
  @google {8, 8, 8, 8}
  @cloudflare {0x2606, 0x4700, 0, 0, 0, 0, 0, 0x1111}

  defp policy(ports \\ [443]), do: EgressPolicy.policy(hosts: [@host], ports: ports)

  # Counts calls by messaging the test process; the resolver runs in the caller.
  defp resolver(answer) do
    test = self()

    fn host ->
      send(test, {:resolved, host})
      answer.()
    end
  end

  defp answering(addresses), do: resolver(fn -> {:ok, addresses} end)

  defp ip(text) do
    {:ok, address} = :inet.parse_address(String.to_charlist(text))
    address
  end

  defp resolve_one(address) do
    result = EgressPolicy.resolve(@url, policy(), answering([address]))
    assert_received {:resolved, @host}
    result
  end

  defp long_label(byte, size), do: String.duplicate(byte, size)

  # 2048 bytes in total with an otherwise valid URL.
  defp url_of_size(size) do
    prefix = "https://api.example.com/"
    prefix <> String.duplicate("a", size - byte_size(prefix))
  end

  describe "admission" do
    test "admits an allowlisted https URL whose every address is public" do
      assert {:ok, %{host: @host, port: 443, addresses: [@google, @cloudflare]}} =
               EgressPolicy.resolve(@url, policy(), answering([@cloudflare, @google]))

      assert_received {:resolved, @host}
      assert EgressPolicy.check(@url, policy()) == {:ok, %{host: @host, port: 443}}
    end

    test "lowercases scheme and host and accepts the explicit default port" do
      url = "HTTPS://API.Example.com:443/"
      assert EgressPolicy.check(url, policy()) == {:ok, %{host: @host, port: 443}}

      assert {:ok, %{host: @host, port: 443, addresses: [@google]}} =
               EgressPolicy.resolve(url, policy(), answering([@google]))

      assert_received {:resolved, @host}
    end

    test "admits port 8443 only when it is allowlisted" do
      url = "https://api.example.com:8443/x"
      assert EgressPolicy.check(url, policy([443, 8443])) == {:ok, %{host: @host, port: 8443}}
      assert EgressPolicy.check(url, policy()) == {:error, :port}

      assert {:ok, %{port: 8443}} =
               EgressPolicy.resolve(url, policy([443, 8443]), answering([@google]))
    end

    test "admits names at the length and label bounds and non-numeric last labels" do
      max_label = long_label("a", 63) <> ".example.com"
      # 127 one-byte labels: 253 bytes.
      max_name = Enum.map_join(1..127, ".", fn _ -> "a" end)

      sized_name =
        Enum.join(
          [long_label("a", 63), long_label("b", 63), long_label("c", 63), long_label("d", 61)],
          "."
        )

      assert byte_size(max_name) == 253
      assert byte_size(sized_name) == 253

      for host <- [
            max_label,
            max_name,
            sized_name,
            "xn--bcher-kva.example",
            "a--b.example.com",
            "1.2.3.example",
            "example.123a",
            "example.0xg",
            "example.x0",
            "0x7f.example"
          ] do
        assert EgressPolicy.check(
                 "https://#{host}/",
                 EgressPolicy.policy(hosts: [host], ports: [443])
               ) ==
                 {:ok, %{host: host, port: 443}},
               host
      end
    end
  end

  # Group 2: one fault per case on an otherwise valid URL.
  @malformed [
    {:non_binary, ~c"https://api.example.com/"},
    {:non_binary_nil, nil},
    {:bitstring, <<1::1>>},
    {:empty, ""},
    {:space, "https://api example.com/"},
    {:backslash, "https://api.example.com\\x"},
    {:newline, "https://api.example.com/\n"},
    {:non_ascii_host, "https://äpi.example.com/"},
    {:no_slashes, "https:api.example.com"},
    {:empty_host, "https:///x"},
    {:userinfo, "https://user:pass@api.example.com/"},
    {:empty_userinfo, "https://@api.example.com/"},
    {:fragment, "https://api.example.com/#frag"},
    {:empty_fragment, "https://api.example.com/#"}
  ]

  @scheme [
    {:http, "http://api.example.com/"},
    {:ftp, "ftp://api.example.com/"},
    {:no_scheme, "//api.example.com/"}
  ]

  @host_refused [
    {:ipv6_loopback, "https://[::1]/"},
    {:ipv4_loopback, "https://127.0.0.1/"},
    {:short_ipv4, "https://127.1/"},
    {:hex_first_octet, "https://0x7f.0.0.1/"},
    {:hex_tail, "https://127.0x1/"},
    {:hex_last_octet, "https://127.0.0.0x1/"},
    {:decimal_ipv4, "https://2130706433/"},
    {:hex_pair, "https://0x7f.0x1/"},
    {:hex_short, "https://1.0xa/"},
    {:bare_hex, "https://example.0x/"},
    {:upper_hex, "https://example.0XAB/"},
    {:percent_encoded, "https://%61pi.example.com/"},
    {:trailing_dot, "https://api.example.com./"},
    {:empty_label, "https://api..example.com/"},
    {:single_label, "https://localhost/"},
    {:numeric_last_label, "https://api.example.123/"},
    {:label_64, "https://#{String.duplicate("a", 64)}.example.com/"},
    {:name_254,
     "https://" <>
       Enum.join(
         [
           String.duplicate("a", 63),
           String.duplicate("b", 63),
           String.duplicate("c", 63),
           String.duplicate("d", 62)
         ],
         "."
       ) <>
       "/"},
    {:leading_hyphen, "https://-api.example.com/"},
    {:trailing_hyphen, "https://api-.example.com/"},
    {:last_label_trailing_hyphen, "https://api.example.com-/"},
    {:underscore, "https://api_v1.example.com/"}
  ]

  @not_allowed [
    {:prefix, "https://evil-api.example.com/"},
    {:suffix, "https://api.example.com.evil.com/"},
    {:parent, "https://example.com/"},
    {:child, "https://x.api.example.com/"}
  ]

  @port [
    {:port_0, "https://api.example.com:0/"},
    {:port_65536, "https://api.example.com:65536/"},
    {:port_444, "https://api.example.com:444/"}
  ]

  @refusals for({name, url} <- @malformed, do: {name, url, :malformed}) ++
              for({name, url} <- @scheme, do: {name, url, :scheme}) ++
              for({name, url} <- @host_refused, do: {name, url, :host}) ++
              for({name, url} <- @not_allowed, do: {name, url, :not_allowed}) ++
              for({name, url} <- @port, do: {name, url, :port})

  describe "check order" do
    test "the length fixtures sit just past their bounds" do
      {_, url, _} = List.keyfind(@refusals, :name_254, 0)
      assert byte_size(URI.parse(url).host) == 254
      {_, url, _} = List.keyfind(@refusals, :label_64, 0)

      assert url |> URI.parse() |> Map.fetch!(:host) |> String.split(".") |> hd() |> byte_size() ==
               64
    end

    test "each single fault returns its reason, and the resolver is never called" do
      for {name, url, reason} <- @refusals do
        assert EgressPolicy.check(url, policy()) == {:error, reason}, inspect(name)

        assert EgressPolicy.resolve(url, policy(), answering([@google])) == {:error, reason},
               inspect(name)

        refute_received {:resolved, _}, inspect(name)
      end
    end

    test "2048 bytes pass and 2049 bytes are malformed" do
      assert byte_size(url_of_size(2048)) == 2048
      assert {:ok, _} = EgressPolicy.check(url_of_size(2048), policy())
      assert {:ok, _} = EgressPolicy.resolve(url_of_size(2048), policy(), answering([@google]))
      assert_received {:resolved, @host}

      assert EgressPolicy.check(url_of_size(2049), policy()) == {:error, :malformed}

      assert EgressPolicy.resolve(url_of_size(2049), policy(), answering([@google])) ==
               {:error, :malformed}

      refute_received {:resolved, _}
    end

    test "earlier faults win over later ones" do
      both = [
        {"http://user@api.example.com/", :malformed},
        {"http://127.0.0.1/", :scheme},
        {"https://127.0.0.1:444/", :host},
        {"https://example.com:444/", :not_allowed}
      ]

      for {url, reason} <- both,
          do: assert(EgressPolicy.check(url, policy()) == {:error, reason}, url)
    end
  end

  describe "resolver Need" do
    test "is called once with the lowercased host" do
      assert {:ok, _} =
               EgressPolicy.resolve("https://API.EXAMPLE.COM/", policy(), answering([@google]))

      assert_received {:resolved, @host}
      refute_received {:resolved, _}
    end

    test "nxdomain and an empty answer are dns_failed" do
      for answer <- [fn -> {:error, :nxdomain} end, fn -> {:ok, []} end] do
        assert EgressPolicy.resolve(@url, policy(), resolver(answer)) == {:error, :dns_failed}
        assert_received {:resolved, @host}
        refute_received {:resolved, _}
      end
    end

    test "unavailable, malformed answers and abnormal returns are unavailable" do
      answers = [
        fn -> {:error, :unavailable} end,
        fn -> {:error, :timeout} end,
        fn -> {:ok, :x} end,
        fn -> :ok end,
        fn -> {:ok, [@google | @google]} end,
        fn -> {:ok, [{1, 2, 3, 4, 5}]} end,
        fn -> {:ok, [{8, 8, 8, 256}]} end,
        fn -> {:ok, [{8, 8, 8, -1}]} end,
        fn -> {:ok, [{8, 8, 8, 8.0}]} end,
        fn -> {:ok, [{0x2606, 0x4700, 0, 0, 0, 0, 0, 0x10000}]} end,
        fn -> {:ok, [{1, 2, 3}]} end,
        fn -> {:ok, ["8.8.8.8"]} end,
        fn -> {:ok, [@google, {8, 8, 8, 256}]} end,
        fn -> {:ok, [{10, 0, 0, 1}, {8, 8, 8, 256}]} end,
        fn -> {:ok, for(n <- 1..33, do: {8, 8, 8, n})} end,
        fn -> {:ok, List.duplicate(@google, 33)} end,
        fn -> raise "boom api.example.com" end,
        fn -> throw(:api) end,
        fn -> exit(:api) end
      ]

      for answer <- answers do
        assert EgressPolicy.resolve(@url, policy(), resolver(answer)) == {:error, :unavailable}
        assert_received {:resolved, @host}
        refute_received {:resolved, _}
      end
    end

    test "a resolver of the wrong shape is unavailable" do
      assert EgressPolicy.resolve(@url, policy(), fn -> {:ok, [@google]} end) ==
               {:error, :unavailable}

      assert EgressPolicy.resolve(@url, policy(), :not_a_function) == {:error, :unavailable}
    end

    test "32 addresses pass and duplicates are coalesced in term order" do
      many = for n <- 32..1//-1, do: {8, 8, 8, n}

      assert {:ok, %{addresses: addresses}} = EgressPolicy.resolve(@url, policy(), answering(many))
      assert addresses == Enum.map(1..32, &{8, 8, 8, &1})

      assert {:ok, %{addresses: [@google]}} =
               EgressPolicy.resolve(@url, policy(), answering(List.duplicate(@google, 32)))

      answer = [@cloudflare, {9, 9, 9, 9}, @google, @cloudflare, {9, 9, 9, 9}]

      assert {:ok, %{addresses: [@google, {9, 9, 9, 9}, @cloudflare]}} =
               EgressPolicy.resolve(@url, policy(), answering(answer))
    end
  end

  # Group 4: both sides of every boundary, each on its own single-address answer.
  @ipv4 [
    {"0.0.0.0", false},
    {"0.255.255.255", false},
    {"1.0.0.0", true},
    {"9.255.255.255", true},
    {"10.0.0.0", false},
    {"10.255.255.255", false},
    {"11.0.0.0", true},
    {"100.63.255.255", true},
    {"100.64.0.0", false},
    {"100.127.255.255", false},
    {"100.128.0.0", true},
    {"126.255.255.255", true},
    {"127.0.0.0", false},
    {"127.0.0.1", false},
    {"127.255.255.255", false},
    {"128.0.0.0", true},
    {"169.253.255.255", true},
    {"169.254.0.0", false},
    {"169.254.169.254", false},
    {"169.254.255.255", false},
    {"169.255.0.0", true},
    {"172.15.255.255", true},
    {"172.16.0.0", false},
    {"172.31.255.255", false},
    {"172.32.0.0", true},
    {"191.255.255.255", true},
    {"192.0.0.0", false},
    {"192.0.0.255", false},
    {"192.0.1.0", true},
    {"192.0.1.255", true},
    {"192.0.2.0", false},
    {"192.0.2.255", false},
    {"192.0.3.0", true},
    {"192.88.98.255", true},
    {"192.88.99.0", false},
    {"192.88.99.255", false},
    {"192.88.100.0", true},
    {"192.167.255.255", true},
    {"192.168.0.0", false},
    {"192.168.255.255", false},
    {"192.169.0.0", true},
    {"198.17.255.255", true},
    {"198.18.0.0", false},
    {"198.19.255.255", false},
    {"198.20.0.0", true},
    {"198.51.99.255", true},
    {"198.51.100.0", false},
    {"198.51.100.255", false},
    {"198.51.101.0", true},
    {"203.0.112.255", true},
    {"203.0.113.0", false},
    {"203.0.113.255", false},
    {"203.0.114.0", true},
    {"223.255.255.255", true},
    {"224.0.0.0", false},
    {"239.255.255.255", false},
    {"240.0.0.0", false},
    {"255.255.255.255", false},
    {"8.8.8.8", true}
  ]

  @ipv6 [
    {"::", false},
    {"::1", false},
    {"::8.8.8.8", false},
    {"fe80::1", false},
    {"fc00::1", false},
    {"fd00::1", false},
    {"ff02::1", false},
    {"64:ff9b::7f00:1", false},
    {"64:ff9b::808:808", false},
    {"1fff:ffff:ffff:ffff:ffff:ffff:ffff:ffff", false},
    {"2000::", true},
    {"2000:ffff:ffff:ffff:ffff:ffff:ffff:ffff", true},
    {"2001::", false},
    {"2001::1", false},
    {"2001:1ff::1", false},
    {"2001:1ff:ffff:ffff:ffff:ffff:ffff:ffff", false},
    {"2001:200::", true},
    {"2001:200::1", true},
    {"2001:db7:ffff:ffff:ffff:ffff:ffff:ffff", true},
    {"2001:db8::", false},
    {"2001:db8::1", false},
    {"2001:db8:ffff:ffff:ffff:ffff:ffff:ffff", false},
    {"2001:db9::", true},
    {"2001:ffff:ffff:ffff:ffff:ffff:ffff:ffff", true},
    {"2002::", false},
    {"2002::1", false},
    {"2002:ffff:ffff:ffff:ffff:ffff:ffff:ffff", false},
    {"2003::", true},
    {"2606:4700::1111", true},
    {"3ffe:ffff:ffff:ffff:ffff:ffff:ffff:ffff", true},
    {"3fff::", false},
    {"3fff::1", false},
    {"3fff:fff:ffff:ffff:ffff:ffff:ffff:ffff", false},
    {"3fff:1000::", true},
    {"3fff:1000::1", true},
    {"3fff:ffff:ffff:ffff:ffff:ffff:ffff:ffff", true},
    {"4000::", false},
    {"4000::1", false},
    {"::ffff:8.8.8.8", true},
    {"::ffff:1.0.0.0", true},
    {"::ffff:223.255.255.255", true},
    {"::ffff:0.0.0.0", false},
    {"::ffff:10.0.0.1", false},
    {"::ffff:127.0.0.1", false},
    {"::ffff:169.254.169.254", false},
    {"::ffff:255.255.255.255", false},
    {"::fffe:808:808", false},
    {"::1:ffff:808:808", false}
  ]

  describe "address table" do
    test "classifies both sides of every IPv4 boundary" do
      for {text, public?} <- @ipv4 do
        assert_classified(text, public?)
      end
    end

    test "classifies IPv6, IPv4-mapped and IPv6 boundaries" do
      for {text, public?} <- @ipv6 do
        assert_classified(text, public?)
      end
    end

    defp assert_classified(text, true) do
      address = ip(text)
      assert {:ok, %{addresses: [^address]}} = resolve_one(address), text
    end

    defp assert_classified(text, false) do
      assert resolve_one(ip(text)) == {:error, :non_public_address}, text
    end
  end

  describe "rebinding" do
    test "a mixed or private answer for an allowlisted name is refused" do
      for answer <- [
            [@google, {10, 0, 0, 1}],
            [{10, 0, 0, 1}, @google],
            [{127, 0, 0, 1}],
            [@cloudflare, ip("::1")]
          ] do
        assert EgressPolicy.resolve(@url, policy(), answering(answer)) ==
                 {:error, :non_public_address},
               inspect(answer)

        assert_received {:resolved, @host}
      end
    end
  end

  describe "policy config" do
    test "accepts both option orders and the bounds" do
      hosts = for n <- 1..256, do: "h#{n}.example.com"
      ports = Enum.to_list(1..15) ++ [65_535]

      assert %EgressPolicy{} = EgressPolicy.policy(hosts: hosts, ports: ports)
      assert %EgressPolicy{} = EgressPolicy.policy(ports: [443], hosts: [@host])

      big = EgressPolicy.policy(hosts: hosts, ports: ports)

      assert {:ok, %{host: "h256.example.com", port: 65_535}} =
               EgressPolicy.check("https://h256.example.com:65535/", big)

      assert {:ok, %{port: 1}} = EgressPolicy.check("https://h1.example.com:1/", big)
    end

    test "raises the fixed ArgumentError on every invalid option set" do
      hosts = for n <- 1..257, do: "h#{n}.example.com"

      invalid = [
        [],
        [hosts: [@host]],
        [ports: [443]],
        [hosts: [@host], ports: [443], extra: true],
        [hosts: [@host], hosts: [@host], ports: [443]],
        [hosts: [@host], ports: [443], ports: [443]],
        %{hosts: [@host], ports: [443]},
        [{:hosts, [@host]} | {:ports, [443]}],
        nil,
        [hosts: [], ports: [443]],
        [hosts: hosts, ports: [443]],
        [hosts: Enum.take(hosts, 1) ++ Enum.take(hosts, 1), ports: [443]],
        [hosts: "api.example.com", ports: [443]],
        [hosts: [@host | "other.example.com"], ports: [443]],
        [hosts: ["API.example.com"], ports: [443]],
        [hosts: ["api.example.com."], ports: [443]],
        [hosts: ["127.0.0.1"], ports: [443]],
        [hosts: ["127.0x1"], ports: [443]],
        [hosts: ["::1"], ports: [443]],
        [hosts: ["[::1]"], ports: [443]],
        [hosts: ["localhost"], ports: [443]],
        [hosts: [~c"api.example.com"], ports: [443]],
        [hosts: [@host], ports: []],
        [hosts: [@host], ports: Enum.to_list(1..17)],
        [hosts: [@host], ports: [443, 443]],
        [hosts: [@host], ports: [0]],
        [hosts: [@host], ports: [65_536]],
        [hosts: [@host], ports: [-443]],
        [hosts: [@host], ports: [443.0]],
        [hosts: [@host], ports: ["443"]],
        [hosts: [@host], ports: 443]
      ]

      for opts <- invalid do
        error = assert_raise ArgumentError, fn -> EgressPolicy.policy(opts) end
        assert Exception.message(error) == @invalid, inspect(opts)
      end
    end
  end

  describe "secrecy" do
    @secret "s3cr3t"

    test "no refusal or raised message carries URL, host, query or userinfo bytes" do
      urls =
        for {_name, url, _reason} <- @refusals, is_binary(url), do: url

      tagged = [
        "https://#{@secret}:pw@api.example.com/?#{@secret}=1",
        "https://api.example.com/?q=#{@secret}#frag",
        "http://api.example.com/?q=#{@secret}",
        "https://#{@secret}.example.com/?q=#{@secret}",
        "https://#{@secret}.0x1/",
        "https://api.example.com:444/?q=#{@secret}"
      ]

      answers = [
        fn -> {:error, :nxdomain} end,
        fn -> {:error, :unavailable} end,
        fn -> raise ArgumentError, "api.example.com #{@secret}" end,
        fn -> throw(@secret) end,
        fn -> exit(@secret) end,
        fn -> {:ok, [{10, 0, 0, 1}]} end,
        fn -> {:ok, [@google, {127, 0, 0, 1}]} end
      ]

      log =
        capture_log(fn ->
          for url <- urls ++ tagged do
            for result <- [
                  EgressPolicy.check(url, policy()),
                  EgressPolicy.resolve(url, policy(), answering([@google]))
                ] do
              assert match?({:error, reason} when is_atom(reason), result), url
              refute inspect(result) =~ @secret
              refute inspect(result) =~ "example"
            end
          end

          for answer <- answers do
            url = "https://api.example.com/?q=#{@secret}"
            result = EgressPolicy.resolve(url, policy(), resolver(answer))
            assert match?({:error, reason} when is_atom(reason), result)
            refute inspect(result) =~ @secret
            refute inspect(result) =~ "example"
          end

          for opts <- [
                [hosts: ["#{@secret}.example.com."], ports: [443]],
                [hosts: ["#{@secret}.example.com", "#{@secret}.example.com"], ports: [443]],
                [hosts: ["#{@secret}.example.com"], ports: [0]],
                [hosts: ["#{@secret}.example.com"], ports: [443], userinfo: @secret]
              ] do
            error = assert_raise ArgumentError, fn -> EgressPolicy.policy(opts) end
            refute Exception.message(error) =~ @secret
          end
        end)

      assert log == ""
    end
  end
end
