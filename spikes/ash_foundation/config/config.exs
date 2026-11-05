import Config
config :logger, level: :warning
config :ash, default_string_length_count: :codepoints
config :elzoo_ash_spike, ash_domains: [ElzooAshSpike.Work]
config :ash, :validate_domain_config_inclusion?, true
config :ash, :policies, show_policy_breakdowns?: true
