# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Notification.Outcome do
  @moduledoc false
  # Elixir side of the Cure decision Elzoo.NotificationOutcome.classify/2.
  @core :"Cure.Elzoo.NotificationOutcome"
  @tags %{
    TagAccepted: :accepted,
    TagInvalidAddress: :invalid_address,
    TagTooLarge: :too_large,
    TagProviderTooLarge: :provider_too_large,
    TagRejectedRecipient: :rejected_recipient,
    TagThrottled: :throttled,
    TagSessionThrottled: :session_throttled,
    TagAuthenticationFailed: :authentication_failed,
    TagCredentialsUnavailable: :credentials_unavailable,
    TagConnectFailed: :connect_failed,
    TagConnectionLost: :connection_lost,
    TagDeadline: :deadline,
    TagUnclassifiedReply: :unclassified_reply,
    TagAdapterError: :adapter_error
  }
  @stages [:MailPre, :MailSession, :MailTransaction, :MailExpired, :MailCrashed]

  def classify(stage, reply) when stage in @stages do
    Map.fetch!(@tags, apply(@core, :classify, [stage, reply]))
  rescue
    _ -> :adapter_error
  end

  def classify(_, _), do: :adapter_error
end
