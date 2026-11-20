# integration/egress-policy

One bounded Policy that decides whether an outbound URL supplied by a tenant
or a model may be contacted. Admitted means an `https` URL to an exact
allowlisted DNS name and port, all of whose resolved addresses are public.
It returns the address set the caller must connect to.

The Piece is plain Elixir. It reads no clock, opens no socket, emits no
telemetry or log, and ships no HTTP client.

## Interface

- `Elzoo.EgressPolicy.policy(opts)` takes a keyword list with exactly one
  `hosts:` (1..256 unique names that satisfy the name rule as given, so
  already lowercase) and exactly one `ports:` (1..16 unique integers in
  1..65_535), in either order. It returns an opaque policy, or raises
  `ArgumentError` with the fixed message
  `"invalid Elzoo.EgressPolicy options"`.
- `Elzoo.EgressPolicy.check(url, policy)` is pure. It returns
  `{:ok, %{host: host, port: port}}` (host lowercased, port explicit or 443)
  or `{:error, reason}` with `reason` in
  `:malformed | :scheme | :host | :not_allowed | :port`.
- `Elzoo.EgressPolicy.resolve(url, policy, resolver)` returns
  `{:ok, %{host: host, port: port, addresses: addresses}}` or
  `{:error, reason}`, where `reason` is one of `check/2`'s or
  `:dns_failed | :unavailable | :non_public_address`. `addresses` are
  distinct `:inet` 4- or 8-tuples in Erlang term order.

The policy is construction-time Config: there is no hot update. Build a new
policy to change the allowlist.

### Order of `check/2`

1. `url` is a binary of 1..2048 bytes, `URI.new/1` succeeds, the host is a
   non-empty binary, and there is no userinfo (also not an empty `@`) and no
   fragment (also not an empty trailing `#`); else `:malformed`.
2. The scheme is `"https"` (`URI.new/1` lowercases it); else `:scheme`.
3. The host, after ASCII lowercasing, satisfies the name rule; else `:host`.
4. The host is in `hosts`; else `:not_allowed`.
5. The port (`URI` default 443) is in `ports`; else `:port`.

### Name rule

A name has 2..127 labels joined by `.`, at most 253 bytes in total. Each
label is 1..63 bytes of `[a-z0-9-]`, neither starting nor ending with `-`.
The last label is neither all digits nor `0x` followed by zero or more hex
digits, because WHATWG and `:inet.parse_address/1` read such names as IPv4.
So every IP literal is refused, including `[::1]`, `127.1`, `0x7f.0.0.1`,
`127.0x1` and `2130706433`, as are percent-encoded and trailing-dot hosts.
Punycode `xn--` labels pass; `URI.new/1` refuses non-ASCII hosts.

### Resolver Need

`resolve/3` runs `check/2` first and calls `resolver.(host)` exactly once,
only after it passes, with the lowercased host. The resolver returns
`{:ok, [address]}` (1..32 tuples, counted before coalescing),
`{:error, :nxdomain}` or `{:error, :unavailable}`.

| Resolver outcome | Result |
| --- | --- |
| `{:error, :nxdomain}` or `{:ok, []}` | `:dns_failed` |
| `{:error, :unavailable}`, any other value, a malformed or 33rd address, a raise, a throw or an exit | `:unavailable` |
| any address not public | `:non_public_address` |
| every address public | `{:ok, ...}` with the distinct addresses |

The answer is all or nothing: a mixed public and private answer is refused,
so no choice of address can reopen a rebinding race.

### Public addresses

An IPv4 address is public unless it is in 0.0.0.0/8, 10.0.0.0/8,
100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.0.0.0/24,
192.0.2.0/24, 192.88.99.0/24, 192.168.0.0/16, 198.18.0.0/15,
198.51.100.0/24, 203.0.113.0/24, 224.0.0.0/4 or 240.0.0.0/4.

An IPv4-mapped IPv6 address (`::ffff:a.b.c.d`) is classified as its IPv4
address. Every other IPv6 address is public only inside 2000::/3 and outside
2001::/23, 2001:db8::/32, 2002::/16 and 3fff::/20. This refuses loopback,
unspecified, IPv4-compatible, link-local, unique-local, multicast, NAT64
64:ff9b::/96, Teredo, 6to4 and documentation addresses.

The table is the Piece's own fixed table, no wider than the globally
reachable set of the IANA special-purpose registries.

### Errors

Errors are the fixed atoms above and never echo the URL, host, query or
userinfo. A resolver exception is caught and becomes `:unavailable`; its
message is not returned.

## Resolver recipe

This is consumer code, not evidence. It resolves both families through
`:inet.getaddrs/3`, each with its own timeout, and treats a partial failure
as unavailable:

```elixir
resolver = fn host ->
  name = String.to_charlist(host)

  case {:inet.getaddrs(name, :inet, 2_000), :inet.getaddrs(name, :inet6, 2_000)} do
    {{:ok, v4}, {:ok, v6}} -> {:ok, v4 ++ v6}
    {{:ok, v4}, {:error, :nxdomain}} -> {:ok, v4}
    {{:error, :nxdomain}, {:ok, v6}} -> {:ok, v6}
    {{:error, :nxdomain}, {:error, :nxdomain}} -> {:error, :nxdomain}
    _other -> {:error, :unavailable}
  end
end

policy = Elzoo.EgressPolicy.policy(hosts: ["api.example.com"], ports: [443])
Elzoo.EgressPolicy.resolve("https://api.example.com/v1", policy, resolver)
```

## Transport duties

These belong to the transport, not to this Piece:

- connect only to one returned address, with SNI and the `Host` header set to
  the returned `host`;
- treat a redirect as a new URL and pass it through `resolve/3` again;
- bound the response body and the connect and read time.

The Level 3 consumer `integration/mcp-runtime` hands these addresses to the
`:dns_resolver` option of the ex_mcp 1.8.1 HTTP transport. No fetch helper is
built here: Req 0.7.5 with `connect_options: [hostname: h]` starts one Finch
instance per distinct hostname and never stops it, so a Req-based guard would
grow without bound on tenant-supplied hosts.

## Limits

- No HTTP client, redirect following or response bound.
- No wildcard or suffix host and no IP-literal allowlist.
- No private-network opt-in.
- No DNS timeout or cache of its own: the resolver Need bounds itself.
- Addresses are only as fresh as the resolver's answer.
