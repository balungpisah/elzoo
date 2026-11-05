# SPDX-License-Identifier: Apache-2.0
# Set ELZOO_HTTP_URL to an endpoint you intend to call.
request =
  Req.new(
    url: System.fetch_env!("ELZOO_HTTP_URL"),
    retry: false,
    redirect: false,
    decode_body: false,
    receive_timeout: 5000
  )

case Req.get(request) do
  {:ok, response} -> IO.inspect({response.status, response.body})
  {:error, exception} -> IO.inspect({:transport_error, exception})
end
