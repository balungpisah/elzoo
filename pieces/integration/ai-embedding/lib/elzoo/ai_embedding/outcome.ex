# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AiEmbedding.Outcome do
  @moduledoc """
  Elixir side of the Cure decision `Elzoo.AiEmbeddingOutcome`: the exact finite
  mapping from a failure tag to the Contract outcome and to the delivery result
  `{outcome, dispatch, error_class}` used by the `delivery/effect-intent`
  Binding. `failures/0` is the static table the Binding compiles (Cure modules
  are compiled after Elixir, so the Binding cannot call them at build time);
  `verify/0` checks at run time that the table equals the Cure decision, and
  `Elzoo.AiEmbedding.configure/1` refuses construction otherwise.
  """
  @core :"Cure.Elzoo.AiEmbeddingOutcome"

  @cure_tags %{
    credentials_unavailable: :TagCredentialsUnavailable,
    provider_invalid_request: :TagProviderInvalidRequest,
    provider_too_large: :TagProviderTooLarge,
    authentication_failed: :TagAuthenticationFailed,
    permission_denied: :TagPermissionDenied,
    not_found: :TagNotFound,
    throttled: :TagThrottled,
    overloaded: :TagOverloaded,
    provider_error: :TagProviderError,
    provider_timeout: :TagProviderTimeout,
    timeout: :TagTimeout,
    transport: :TagTransport,
    malformed_response: :TagMalformedResponse,
    adapter_error: :TagAdapterError
  }

  # tag => {envelope outcome, dispatch, error_class}
  @failures %{
    credentials_unavailable: {"timed_out", "not_dispatched", "unavailable"},
    provider_invalid_request: {"failed", "dispatched", "permanent"},
    provider_too_large: {"failed", "dispatched", "permanent"},
    authentication_failed: {"failed", "dispatched", "permanent"},
    permission_denied: {"failed", "dispatched", "permanent"},
    not_found: {"failed", "dispatched", "permanent"},
    throttled: {"failed", "dispatched", "retryable"},
    overloaded: {"failed", "dispatched", "retryable"},
    provider_error: {"unknown", "dispatched", "unclassified"},
    provider_timeout: {"timed_out", "unknown", "unclassified"},
    timeout: {"timed_out", "unknown", "unclassified"},
    transport: {"unknown", "unknown", "unclassified"},
    malformed_response: {"unknown", "dispatched", "unclassified"},
    adapter_error: {"unknown", "unknown", "unclassified"}
  }
  # Only a failure before any request byte reached transport.
  @no_send [:credentials_unavailable]

  @outcomes %{
    OutRejected: "rejected",
    OutFailed: "failed",
    OutUnknown: "unknown",
    OutTimedOut: "timed_out"
  }
  @dispatches %{
    DispatchNot: "not_dispatched",
    DispatchDone: "dispatched",
    DispatchUnknown: "unknown"
  }
  @classes %{
    ErrorPermanent: "permanent",
    ErrorRetryable: "retryable",
    ErrorUnavailable: "unavailable",
    ErrorUnclassified: "unclassified"
  }
  @reasons %{
    ReasonCredentialsUnavailable: :credentials_unavailable,
    ReasonInvalidRequest: :invalid_request,
    ReasonTooLarge: :too_large,
    ReasonAuthenticationFailed: :authentication_failed,
    ReasonPermissionDenied: :permission_denied,
    ReasonNotFound: :not_found,
    ReasonThrottled: :throttled,
    ReasonOverloaded: :overloaded,
    ReasonTimeout: :timeout,
    ReasonTransport: :transport,
    ReasonMalformedResponse: :malformed_response,
    ReasonProviderError: :provider_error
  }

  def tags, do: Map.keys(@failures)
  def failures, do: @failures
  def no_send, do: @no_send

  @doc "Tags a provider's `classify_failure/1` may return (not the interface's own)."
  def provider_tags, do: tags() -- [:credentials_unavailable, :adapter_error]

  @doc "Contract outcome of a tag: `{:refused, reason}` or `{:unknown, reason}` (Cure decision)."
  def contract(tag) do
    with {:ok, t} <- Map.fetch(@cure_tags, tag) do
      class = if apply(@core, :class, [t]) == :ClassRefused, do: :refused, else: :unknown
      {:ok, {class, Map.fetch!(@reasons, apply(@core, :reason, [t]))}}
    end
  end

  @doc "Delivery triple of a tag from the Cure decision."
  def delivery(tag) do
    with {:ok, t} <- Map.fetch(@cure_tags, tag) do
      {:ok,
       {Map.fetch!(@outcomes, apply(@core, :outcome, [t])),
        Map.fetch!(@dispatches, apply(@core, :dispatch, [t])),
        Map.fetch!(@classes, apply(@core, :error_class, [t]))}}
    end
  end

  @doc "True when the static Binding table and no-send set equal the Cure decision."
  def verify do
    Enum.all?(@failures, fn {tag, triple} ->
      {:ok, ^triple} = delivery(tag)
      apply(@core, :no_send, [Map.fetch!(@cure_tags, tag)]) == tag in @no_send
    end)
  rescue
    _ -> false
  catch
    _, _ -> false
  end
end
