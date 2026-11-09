# ELZ-080 Contract amendment 1 (proposed; awaiting the main coordinator)

Source: [early review](ELZ-080-early-review.md), blocking findings 1 (served-model identity) and 2
(request bound) and should-fix finding 4 (one norm tolerance), with the orchestrator's wording
(B1, B2, S4). Each "Before" text occurs exactly once in the raw live body (checked byte for
byte, line breaks and indentation included); the replacements are applied in the order listed.
SHA-256 values are of the API `body` string (UTF-8), as `scripts/check-roadmap.py --live`
computes them. The chosen tolerance value `1.0e-3` is the proposal's default; float32 storage
of a unit vector of 3,072 elements moves its norm by far less than that.

## #159 (ELZ-080)

Live body before: SHA-256 `9423641b5dec8f94b9d04e331036a30991e83ff07bed115d035375a38ca2812f`, 10402 bytes.

### 159.1 B2: the request bound (Admission record item 2, Inputs)

Before:

```text
`inputs` (1..N texts, each
   bounded in bytes, total bounded), `dimensions`
```

After:

```text
`inputs` (1..N texts, each
   bounded in bytes; the whole request is bounded by its command payload: the exact
   UTF-8 bytes of the canonical JSON command payload admitted as the ELZ-023 intent's
   `arguments`, every request member and JSON escaping included, must be 1..65,536
   bytes, the `delivery/effect-intent` argument bound, else `refused{too_large}` before
   any intent, credential read or transport call; this is not an HTTP-body limit, and
   a caller whose inputs do not fit splits them across calls), `dimensions`
```

### 159.2 S4: one interface-wide norm tolerance (item 2, Output)

Before:

```text
vector's L2 norm within a stated tolerance) or `none`
```

After:

```text
vector's L2 norm within the interface-wide tolerance `abs(norm_l2(v) - 1) <=
   1.0e-3`, fixed by this Contract and not configurable, so `unit_l2_verified` has one
   meaning in every descriptor) or `none`
```

### 159.3 B1: served-model identity (item 2, Invariants)

Before:

```text
(the provider may have charged), never a shorter list; one call
```

After:

```text
(the provider may have charged), never a shorter list; the response must name a
   nonempty served `model` equal to the requested allowlisted model ID, otherwise the
   call is `unknown{malformed_response}` with no vectors delivered (provenance keeps
   both the requested `model_ref` and the reported `provider_model`; model aliases and
   snapshots need a later Contract); one call
```

### 159.4 S4 consequence: the tolerance is no longer a setting (item 6, Composition record)

Before:

```text
Config `supported` (binding, model allowlist, bounds, deadline, norm tolerance;
   construction time)
```

After:

```text
Config `supported` (binding, model allowlist, bounds, deadline;
   construction time; the norm tolerance is fixed by the Contract, not a setting)
```

Amended body: SHA-256 `23d483c9abce814a58d198a5b0dec8613a13dae2bc80542c9ddb7ae4a93fc874`, 11371 bytes. No other byte changes.

## #160 (ELZ-082, not claimed): matching note

Live body before: SHA-256 `a8122939b108697a2fdb8a1582dae82ee5e1fce65ac0a0b2eb31299d6a776d63`, 12695 bytes.

### 160.1 Indexing caller and the ELZ-080 request bound (item 2, Invariants)

Before:

```text
digest, offsets, embedding provenance). The store
```

After:

```text
digest, offsets, embedding provenance). The store does not call ELZ-080: its
   indexing caller groups chunks into one ELZ-080 call only while that call's
   canonical command payload fits ELZ-080's 1..65,536-byte bound (a chunk whose text
   alone exceeds it cannot be embedded, so it cannot be indexed in this slice), and it
   handles an ELZ-080 refusal or unknown outcome itself, writing no partial source. The store
```

Amended body: SHA-256 `d8cb5470b35d1007b6482d24a1b4d2abeb9bed66c2a86882afd6a0ef856c7b6b`, 13066 bytes. No other byte changes.

After the coordinator edits the live bodies, the task copy `tasks/ELZ-080-*.md` and the
release-plan `issue_body_sha256` are synchronized to the amended #159 body in one commit.

The full amended bodies are in `ELZ-080-amendment-1/issue-159-body.txt` and
`issue-160-body.txt` (byte-exact; their SHA-256 values are the ones above).
