# ELZ-137 — Mark content that must not give orders

## Scope and reuse

- Dependencies: ELZ-033, ELZ-083, ELZ-030, ELZ-002, ELZ-003
- Output: `workflow/untrusted-content`; release V1B; bot-platform level 1.
- Owned paths: `pieces/workflow/untrusted-content/**` and its index/generated changes under AGENTS.md section 3.

A tool result, a retrieved document and a message from another member are content, not instructions. This Piece is the one shared mark for such content: a value that holds the content with its sources, a trust class and a size bound, and the one format in which a marked value appears in a model request. A prompt builder and a guard can then treat it apart from the instructions of the principal. ELZ-139 and ELZ-140 use exactly this interface and define no second mark.

Implement only the acceptance groups below. Add no options, layers, behaviours, generic helpers or future hooks: no guard, no detector of injected text, no policy, no storage, no process. Change no ready Piece, shared path, dependency pin or CI file. The independent reviewer flags extra features for removal.

Facts checked on main:

- `core/envelope` has no metadata extension and refuses unknown keys (README). So the mark is payload data under its own schema key in the form of `core/port`: a nonempty schema ID and a positive version. The Envelope is unchanged.
- `integration/mcp-client` stamps each discovery descriptor with `"trust" => "untrusted"` and returns tool results with no mark (README). The caller that receives a result marks it with this Piece. mcp-client is unchanged and is not called.
- `workflow/context-selection` calls derived content "an untrusted proposal" and gives each selected entry the kind `:source` or `:derived` (README). The two trust words below are those words.
- No ready Piece is called, so the manifest names no Piece dependency.

## The marked value

The neutral form is a map with exactly these six string keys:

    %{"schema_id" => "elzoo.untrusted-content.marked", "schema_version" => 1,
      "sources" => ["mcp:files/read_file"], "trust" => "untrusted",
      "max_bytes" => 4096, "content" => "text of the result"}

- `schema_id` and `schema_version` are exactly this pair. A marked value keeps them when it is a part of a larger payload, so a reader finds it by its key.
- `sources`: 1 to 16 distinct texts in order, each 1 to 256 bytes of `[A-Za-z0-9._:/@-]`. A value from one source has one entry. The trusted host or pattern writes it; content never supplies it.
- `trust`: `"untrusted"` or `"derived"`, a closed version-1 set. `untrusted` is content as its source gave it. `derived` is text that a model made from other content, for example a summary. `derived` is the least trusted class: context-selection admits derived content only under `allow_derived`, on top of every check of its sources.
- `max_bytes`: an integer from 1 to 16,777,216, the size bound that the caller declares.
- `content`: valid UTF-8 text of at most `max_bytes` bytes. It can be empty. Bytes that are not text travel as base64 text, and the encoding is named beside the value (ELZ-139).

Each field is JSON data, so the map goes into a record and comes back as it is.

Every marked value is content, whatever its class. The class is a label for a prompt builder and a guard. A mark never grants and never removes authority: authority comes only from the principal. Named skill instructions are instructions and get no mark. They come only from a tool source of kind `pinned_skill` in the registry snapshot of ELZ-136, whose kinds are `pinned_skill`, `host_listing` and `other`. The caller decides that from the snapshot, never from a path or from the shape of a result, and this Piece never sees the kind.

## Interface

One public module, `Elzoo.UntrustedContent`, with five functions. It follows the map and checked-value boundary of `Elzoo.Port` and `Elzoo.PatternStep`.

- `decode(term)` returns `{:ok, marked}` or `{:error, :invalid_shape}`. It is the only way to make a marked value: a caller marks content by building the map above. A missing key, an unknown key, another schema pair, a source outside the grammar, a repeated source, more than 16 sources, an unknown class, a bound outside its range, and content that is not UTF-8 or is over `max_bytes` are all `:invalid_shape`. No error holds a value.
- `encode(marked)` returns the neutral map, and `decode/1` of that map gives an equal value. A caller that changes content, for a cut for example, encodes, replaces `content` and decodes again.
- `concat(a, b)` returns `{:ok, marked}`: the content of `a`, then the content of `b`; the sources of `a`, then each source of `b` that is not yet there; the least trusted of the two classes; and the sum of the two bounds. It returns `{:error, :too_many_sources}` for more than 16 sources and `{:error, :too_large}` for a sum above 16,777,216.
- `wrap(marked, source, trust)` puts a mark around a marked value, for content that reaches the caller through a second source, for example a member that sends on a tool result. The result has the same content and bound. `source` is first in its sources, then the earlier sources with no repeat. Its class is the least trusted of `trust` and the class of the inner value. It returns `{:error, :invalid_shape}` for a bad source or class and `{:error, :too_many_sources}` as above.
- `render(marked)` returns `{:ok, text}`: the one format of a marked value in a model request.

`concat/2`, `wrap/3` and `render/1` are marked-only. An operand that is not a checked value from `decode/1` (a binary, a neutral map that was not decoded, any other term) gives `{:error, :unmarked}`, and nothing is joined or rendered.

The rendered text is exactly these three parts, joined by one line feed, with no line feed at the end:

    <<<untrusted-content TAG trust=TRUST bytes=N sources=SOURCE,SOURCE>>>
    CONTENT
    <<<end untrusted-content TAG>>>

`TAG` is the first 32 lowercase hexadecimal characters of the SHA-256 of the content bytes (OTP `:crypto`). `N` is the byte size of the content in decimal. The sources stand in their order with commas between them. The content is not changed and not escaped. The tag depends on the content, so the content cannot hold the closing line of its own block, unless someone finds a text that holds the first 128 bits of its own SHA-256. That is a claim about the format. It is not a claim about what a model does with the block.

The checked value is opaque to callers; the README documents it for source-copy ownership. Cure owns the class decision (two classes in, the least trusted one out). Elixir owns the map check, the text and the hash.

## Needs and limits

Needs: the host or the pattern stamps `sources` and `trust` truthfully and decides what is content. It marks each tool result, retrieved document and member message before the value reaches a prompt builder. It keeps the neutral map whole when it stores or forwards it. For memory that `workflow/context-selection` selected, kind `:source` is `untrusted` and kind `:derived` is `derived`.

Limits: no claim that marking prevents prompt injection. That a model treats a marked block as data is a stated assumption, not a result of this Piece. No check of who made the content, no authentication of a source and no detection of instructions inside content. The checked value is not a security boundary against BEAM code that forges it. A caller that copies `content` out of the value loses the mark. Telemetry, Config and Control are not applicable to these pure functions; the manifest says why.

## Acceptance groups

1. **`mark_survives`**: a fixed version-1 fixture, and values with each class, with 1 and with 16 sources, with empty content and with content of exactly `max_bytes` bytes, go through `decode/1` and `encode/1` and come back equal. The encoded map goes through Jason and back and decodes to an equal value. `concat/2` keeps the bytes of both values in order, each source once and in order, the least trusted class and the summed bound. Each malformed shape named above is refused, and no error holds a value.
2. **`unmarked_refused`**: a binary, a neutral map that was not decoded, `nil` and a tuple with another tag give `{:error, :unmarked}` from `concat/2` on either side, from `wrap/3` and from `render/1`.
3. **`render_format`**: for a fixed fixture the rendered text equals a text that the test holds as a literal, byte for byte. The label holds each source, the class and the byte size. Two contents that differ in one byte get different tags. Content that holds a line `<<<end untrusted-content` with any tag, or a whole rendered block of other content, is rendered unchanged, and the last line of the result is the only line that equals the real closing line.
4. **`nested_least_trusted`**: `wrap/3` of an `untrusted` value with `derived` gives `derived`, and `wrap/3` of a `derived` value with `untrusted` gives `derived`. A mark around a mark around a mark is `derived` when any level is `derived`. `untrusted` around `untrusted` stays `untrusted`. `concat/2` of the two classes gives `derived` in both orders. The outer source is first and no source is lost. A seventeenth source is refused.
5. **Selected law and example**: the Cure law `derived_absorbs` says that the production class decision gives `derived` when either operand is `derived`. One checked example marks a tool result, wraps it and renders it.

Each test input is a literal neutral map. No recorded provider fixture and no credential is used.

Negative controls (edit temporarily, run, record the failure, revert): make the class decision return its left operand, and the law check or `nested_least_trusted` must fail; make `render/1` use a constant tag, and `render_format` must fail.

## Evidence

Keep the kinds apart. Proof: the one selected Cure law, over the closed set of two classes. If the pinned compiler cannot check it, ask the coordinator; do not weaken the claim. Test: the four named groups, which are finite scenarios. Upstream: OTP `:crypto` SHA-256, Jason and the Cure pin. Assumption: truthful stamps of the host, and the behaviour of a model named under Limits. The law says nothing about the map check, the rendering or what a caller marks.

Run the Piece tests, then `mix check --piece "$(git merge-base origin/main HEAD)"` and `git diff --check`. One independent review checks this body, the exact diff and needless features.
