# SPDX-License-Identifier: Apache-2.0
"abc" |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower) |> IO.puts()
