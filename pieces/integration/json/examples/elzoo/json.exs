# SPDX-License-Identifier: Apache-2.0
{:ok, json} = Jason.encode(%{"items" => [1, true, "hello"]})
IO.inspect(Jason.decode(json))
