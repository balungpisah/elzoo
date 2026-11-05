# SPDX-License-Identifier: Apache-2.0
token = make_ref()
Process.send_after(self(), {:elapsed, token}, 0)

receive do
  {:elapsed, ^token} -> IO.puts("Pass this event into your pure transition")
after
  1000 -> raise "timer did not arrive"
end
