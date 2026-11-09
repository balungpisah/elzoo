import Config

config :logger, :console, format: "$time $metadata[$level] $message\n"

# ELZ-079: req_llm must never load a .env file from the working directory; the Anthropic
# provider Piece takes its key only from an injected Need. Every consumer of a
# req_llm-backed provider Piece needs the same line.
config :req_llm, load_dotenv: false
