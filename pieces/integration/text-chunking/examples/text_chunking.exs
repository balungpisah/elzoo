# SPDX-License-Identifier: Apache-2.0
# Chunk one frozen source and cite each chunk by its byte range and digest.
source = """
# Release notes

The importer now keeps byte offsets for every chunk.

Each chunk can be re-read from the frozen source and checked against its digest.
"""

digest = :crypto.hash(:sha256, source)

{:ok, result} =
  Elzoo.TextChunking.chunk(source, digest, "notes/release.md",
    format: :markdown,
    chunk_size: 64,
    chunk_overlap: 16
  )

for chunk <- result.chunks do
  # A later reader re-derives the bytes from the source and checks the digest.
  ^chunk = %{
    chunk
    | content: binary_part(source, chunk.start_byte, chunk.end_byte - chunk.start_byte)
  }

  true = :crypto.hash(:sha256, chunk.content) == chunk.content_digest
  IO.puts("#{chunk.index} [#{chunk.start_byte}, #{chunk.end_byte}) #{inspect(chunk.content)}")
end
