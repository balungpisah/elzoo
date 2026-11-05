# SPDX-License-Identifier: Apache-2.0
1..100
|> Stream.filter(&(rem(&1, 2) == 0))
|> Stream.map(&(&1 * 10))
|> Enum.take(3)
|> IO.inspect()
