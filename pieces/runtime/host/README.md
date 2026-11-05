# runtime/host

Copy and rename `examples/elzoo/host.exs` into the consumer application.
`Elzoo.IngestHost` is a consumer-owned Application and Supervisor callback
module, not a root Elzoo service. `start/2` or `start_link/1` takes a list of
`{child_id, {module, function, initial_state}}` entries and starts `Elzoo.Unit`
children. No `Elzoo.Application` is needed.

The fixed strategy is `one_for_one`, with OTP default intensity (3 restarts in
5 seconds); exceeding it exits the Supervisor. `lookup(supervisor, id)` uses
`Supervisor.which_children/1`: a pid when running, `:restarting` while OTP
restarts, or `:undefined` for an absent or terminated child. Lookup is a
snapshot, not a race-free promise of availability.

Tests load the recipe, exercise construction-time child selection and show
that killing a Unit changes its pid, resets state, and re-accepts a previously
delivered dedup key. These are finite tests relying on OTP's lifecycle
contract, not a proof of all failure interleavings.

State and dedup history are volatile; mailbox/history remain unbounded.
No durability, exactly-once, hot reconfiguration or business drain. Telemetry
is planned; Control inherits OTP lifecycle only. Consumer Logger configuration
owns inherited OTP crash diagnostics, which may contain last request/state.
