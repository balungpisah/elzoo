# integration/http

Use Req directly for an HTTP client request with explicit retry, redirect, body and timeout choices.

## Use

Req.new(url: url, retry: false, redirect: false, decode_body: false, receive_timeout: 5000) |> Req.get(). HTTP status errors are responses; transport failures are {:error, exception}. Set ELZOO_HTTP_URL before running the example.

This directory is a source bundle. See [consumption instructions](../../../docs/consuming.md) for copying selected pieces into a project.

## Dependencies

- Pieces: none
- Providers: req

## Grounding

- **test**: The named scenarios in this ExUnit file are executable evidence, not universal proofs. `test/elzoo/http_recipe_test.exs`
- **upstream**: Relies on the pinned provider implementation and public contract. https://hexdocs.pm/req/0.7.5/Req.html

## Limits

- Local HTTP success/503 are tested; timeout is a deterministic adapter injection.
- No server, SSE, WebSocket, SSRF policy, durable effects, circuit breaker or job integration is provided.
- Req brings Finch transitively; Elzoo does not expose a second independent HTTP abstraction.

Copied source is Apache-2.0. External packages retain their own licenses.
Evidence describes the recorded source bytes and selected scenarios. After
customization, rerun/adapt its checks; the receipt is provenance, not a proof
of your modified application.
