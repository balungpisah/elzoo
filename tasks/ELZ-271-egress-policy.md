# ELZ-271 — Admit an outbound URL only to an allowlisted host whose every address is public

- Phase: Wave 5 Level 2
- Dependencies: ELZ-033
- Release: V1B
- Output: new `integration/egress-policy` Piece
- Change class: Piece-only
- Owned paths: `pieces/integration/egress-policy/**` and its own catalogue/release-plan rows and generated views only. Do not edit root/shared code, another Piece (`integration/http`, `integration/mcp-client`, `integration/mcp-multi`), `mix.exs`, `mix.lock` or CI.

## Outcome and boundary

One bounded Policy, plain Elixir (Cure where a pure decision fits; no new provider). It decides whether an outbound URL that a tenant or a model supplied may be contacted. Admitted means an `https` URL to an exact allowlisted DNS name and port, all of whose resolved addresses are public. It returns the address set the caller must connect to. The address check runs on the resolver's answer, so a host name that resolves to a private address is refused even when the name is allowlisted. Resolution is an injected Need. The Piece reads no clock and opens no socket.

This task ships no HTTP client: connecting, redirects and response size belong to the transport. The Level 3 consumer, `integration/mcp-runtime`, connects through ex_mcp 1.8.1. Its HTTP transport already resolves, refuses non-public answers, and connects through Mint pinned to one checked address. It accepts a `:dns_resolver` function (`resolver.(host, timeout)`; observed in `ExMCP.Transport.HTTP.TargetPolicy`, a `@moduledoc false` module, at the locked version). So that consumer can hand ex_mcp exactly this Piece's addresses. Probe for the record: Req 0.7.5 with `connect_options: [hostname: h]` pins an IP and sends the right `Host` header. But it starts one Finch instance under `Req.FinchSupervisor` per distinct hostname and never stops it (3 hosts gave 3 children). A Req-based guard would therefore grow without bound on tenant-supplied hosts, which is why no fetch helper is built here.

## Interface

- `Elzoo.EgressPolicy.policy(opts)` takes a keyword list with exactly one each of `hosts` (1..256 unique names, each satisfying the name rule below as given, so already lowercase) and `ports` (1..16 unique integers `1..65_535`). It returns an opaque policy, or raises `ArgumentError` with a fixed message that contains no option data.
- `Elzoo.EgressPolicy.check(url, policy)` is pure. It returns `{:ok, %{host: host, port: port}}` (`host` lowercased, `port` explicit or 443) or `{:error, reason}` with `reason` in `:malformed | :scheme | :host | :not_allowed | :port`.
- `Elzoo.EgressPolicy.resolve(url, policy, resolver)` returns `{:ok, %{host: host, port: port, addresses: addresses}}` or `{:error, reason}` with `reason` being one of `check/2`'s or `:dns_failed | :unavailable | :non_public_address`. `addresses` are distinct `:inet` 4- or 8-tuples in Erlang term order. `resolver` is an arity-1 Need called as `resolver.(host)`. It returns `{:ok, [address]}` (1..32 tuples, counted before coalescing), `{:error, :nxdomain}` or `{:error, :unavailable}`. The README shows a recipe over `:inet.getaddrs/3` for both families with a timeout. That recipe is consumer code, not evidence.

Order of `check/2`:

1. `url` is a binary of 1..2048 bytes, `URI.new/1` succeeds, `host` is a non-empty binary, and there is no `userinfo` and no `fragment`; else `:malformed`.
2. `scheme` is `"https"` (`URI.new/1` lowercases it); else `:scheme`.
3. The host, after ASCII lowercasing, satisfies the name rule; else `:host`. This refuses every IP literal, including the hosts of `[::1]`, `127.0.0.1`, `127.1`, `0x7f.0.0.1`, `127.0x1`, `127.0.0.0x1` and `2130706433`, whose `URI` host `:inet.parse_address/1` accepts as loopback. It also refuses percent-encoded and trailing-dot hosts.
4. The host is in `hosts`; else `:not_allowed`.
5. The port (`URI` default 443) is in `ports`; else `:port`.

`resolve/3` runs `check/2` first and calls `resolver` exactly once, only after it passes. `{:error, :nxdomain}` or `{:ok, []}` is `:dns_failed`. `{:error, :unavailable}`, any other result, a malformed or 33rd address, a raise, a throw or an exit is `:unavailable`. Then, if any address is not public, the result is `:non_public_address` (all or nothing: a mixed answer is refused, so no address choice can reopen a rebinding race).

## Name rule and public addresses

A name has 2..127 labels joined by `.`, at most 253 bytes in total. Each label is 1..63 bytes of `[a-z0-9-]`, neither starting nor ending with `-`. The last label is neither all digits nor `0x` followed by zero or more hex digits (WHATWG and `:inet.parse_address/1` read such names as IPv4). Punycode `xn--` labels pass; non-ASCII hosts are already refused by `URI.new/1` (`:malformed`).

An IPv4 address is public unless it is in 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.0.0.0/24, 192.0.2.0/24, 192.88.99.0/24, 192.168.0.0/16, 198.18.0.0/15, 198.51.100.0/24, 203.0.113.0/24, 224.0.0.0/4 or 240.0.0.0/4. An IPv4-mapped IPv6 address (`::ffff:a.b.c.d`) is classified as its IPv4 address. Every other IPv6 address is public only inside 2000::/3 and outside 2001::/23, 2001:db8::/32, 2002::/16 and 3fff::/20. This refuses loopback, unspecified, link-local, unique-local, multicast, NAT64 64:ff9b::/96, Teredo, 6to4 and documentation addresses. Classification is the Piece's own table; ex_mcp's `NetworkPolicy` is `@moduledoc false` and not reused.

Errors are the fixed atoms and never echo the URL or host; the Piece emits no telemetry and no log.

## Acceptance

1. Admission: `https://api.example.com/v1?q=1` with `hosts: ["api.example.com"]`, `ports: [443]` and a resolver answering `[{8,8,8,8}, {0x2606,0x4700,0,0,0,0,0,0x1111}]` gives both addresses. `HTTPS://API.Example.com:443/` passes. `:8443` with `ports: [443, 8443]` passes, and without 8443 is `:port`.
2. `check/2` order, one fault per case on an otherwise valid URL: a non-binary, 0 bytes, 2048 bytes passing and 2049 bytes refused, `URI.new` failures (space, backslash, newline, `ä` in the host), `https:api.example.com` and `https:///x` (no host), userinfo, a fragment and an empty fragment (a trailing `#`, which `URI.new/1` reads as `""`), all `:malformed`. `http://api.example.com/` and `ftp://api.example.com/` are `:scheme`. The IP literals above (including `0x7f.0x1` and `1.0xa`), `%61pi.example.com`, `api.example.com.`, a single label, a numeric last label, a 64-byte label, a 254-byte name and labels with a leading or trailing hyphen are `:host`. `evil-api.example.com`, `api.example.com.evil.com` and `example.com` are `:not_allowed`. Ports 0, 65536 and 444 are `:port`.
3. Resolver Need: not called for any refusal in group 2 (count the calls), and called exactly once otherwise. `:nxdomain` and `[]` are `:dns_failed`. `:unavailable`, `{:ok, :x}`, a 5-tuple, an octet 256, 33 addresses, a raise, a throw and an exit are `:unavailable`. 32 addresses pass. Duplicates are coalesced in the result.
4. Address table, each on its own single-address answer: both sides of every IPv4 boundary (for example 100.63.255.255 public and 100.64.0.0 refused, 100.127.255.255 refused and 100.128.0.0 public; 172.15.255.255 and 172.32.0.0 public, 172.16.0.0 and 172.31.255.255 refused; 198.17.255.255 public and 198.18.0.0 refused; 223.255.255.255 public and 224.0.0.0 refused; 255.255.255.255 refused). IPv6: `::`, `::1`, fe80::1, fc00::1, ff02::1, 64:ff9b::7f00:1, 2001::1, 2001:1ff::1, 2001:db8::1, 2002::1, 3fff::1 and 4000::1 refused; 2001:200::1, 2606:4700::1111 and 3fff:1000::1 public. `::ffff:8.8.8.8` public and `::ffff:127.0.0.1` refused.
5. Rebinding: an allowlisted name answering `[{8,8,8,8}, {10,0,0,1}]` (either order) or only `{127,0,0,1}` is `:non_public_address`.
6. Policy config: a missing or extra option, 0 or 257 hosts, a duplicate host, an uppercase, trailing-dot or IP-literal host (including `127.0x1`), 0 or 17 ports, a duplicate port and port 0 raise the fixed `ArgumentError`.
7. Secrecy: for each refusal, the URL, host, query and userinfo bytes appear in no result and no raised message.
8. Negative controls, one at a time: accept when any address is public; skip the IPv4-mapped classification; call the resolver before the allowlist check; drop the userinfo refusal. Each must make a case of groups 2–5 fail. Restore before the final gates.

Limits to state: no HTTP client, redirect following or response bound (transport duties: connect only to a returned address, with SNI and `Host` set to `host`; treat a redirect as a new URL through `resolve/3`; bound the body). No wildcard or suffix host and no IP-literal allowlist. No private-network opt-in, no DNS timeout or cache of its own (the resolver Need bounds itself). Addresses are as fresh as the answer, and the table is a fixed table no wider than the globally reachable set of the IANA special-purpose registries, plus multicast and NAT64. Run the Piece tests and the new-Piece small gate (including the copied consumer), the roadmap and claims checks and the diff check. One independent review, the exact-head hosted check and the merge queue are required.
