# SPDX-License-Identifier: Apache-2.0
# ELZ-053 provider probe (not a test): run with MIX_ENV=test mix run --no-start <this file> and the
# ELZOO_TEST_S3_* variables of the disposable server (scripts/ci-minio.py). Output: docs/work/ELZ-053.md.
# ELZ-053 provider probe: req_s3 0.2.5 on Req 0.7.5 against the pinned MinIO.
{:ok, _} = Application.ensure_all_started(:req)
url = System.fetch_env!("ELZOO_TEST_S3_URL")
bucket = System.fetch_env!("ELZOO_TEST_S3_BUCKET")
ak = System.fetch_env!("ELZOO_TEST_S3_ACCESS_KEY_ID")
sk = System.fetch_env!("ELZOO_TEST_S3_SECRET_ACCESS_KEY")
region = System.fetch_env!("ELZOO_TEST_S3_REGION")
sigv4 = [access_key_id: ak, secret_access_key: sk, region: region, service: :s3]
req = Req.new(retry: false, aws_sigv4: sigv4, decode_body: false) |> ReqS3.attach(aws_endpoint_url_s3: url)
pre = "probe-#{System.unique_integer([:positive])}"
show = fn label, resp ->
  h = Map.take(resp.headers, ~w(etag x-amz-checksum-sha256 x-minio-error-code content-length x-amz-checksum-type))
  body = if is_binary(resp.body), do: String.slice(resp.body, 0, 220), else: inspect(resp.body)
  IO.puts("#{label}: status=#{resp.status} headers=#{inspect(h)} body=#{inspect(body)}")
end
b64 = fn d -> Base.encode64(:crypto.hash(:sha256, d)) end
data = "hello object store"
show.("P1 put+checksum", Req.put!(req, url: "s3://#{bucket}/#{pre}/a", body: data, headers: [{"x-amz-checksum-sha256", b64.(data)}]))
IO.puts("P1 md5=#{Base.encode16(:crypto.hash(:md5, data), case: :lower)}")
show.("P2 put wrong checksum", Req.put!(req, url: "s3://#{bucket}/#{pre}/b", body: data, headers: [{"x-amz-checksum-sha256", b64.("other")}]))
show.("P3 get checksum-mode", Req.get!(req, url: "s3://#{bucket}/#{pre}/a", headers: [{"x-amz-checksum-mode", "ENABLED"}]))
show.("P3b head checksum-mode", Req.head!(req, url: "s3://#{bucket}/#{pre}/a", headers: [{"x-amz-checksum-mode", "ENABLED"}]))
show.("P4 head missing key", Req.head!(req, url: "s3://#{bucket}/#{pre}/missing"))
show.("P4b head missing bucket", Req.head!(req, url: "s3://no-such-bucket-elz/#{pre}/a"))
show.("P4c head bucket", Req.head!(req, url: "s3://#{bucket}"))
show.("P5 get missing key", Req.get!(req, url: "s3://#{bucket}/#{pre}/missing"))
show.("P5b get missing bucket", Req.get!(req, url: "s3://no-such-bucket-elz/#{pre}/a"))
for i <- 1..5, do: Req.put!(req, url: "s3://#{bucket}/#{pre}/l/#{i}", body: "x#{i}")
r = Req.get!(req, url: "s3://#{bucket}", params: ["list-type": 2, prefix: "#{pre}/l/", "max-keys": 2], decode_body: true)
IO.puts("P6 list page1: #{r.status} #{inspect(r.body)}")
tok = r.body["ListBucketResult"]["NextContinuationToken"]
r2 = Req.get!(req, url: "s3://#{bucket}", params: ["list-type": 2, prefix: "#{pre}/l/", "max-keys": 2, "continuation-token": tok], decode_body: true)
IO.puts("P6 list page2: #{inspect(r2.body)}")
r3 = Req.get!(req, url: "s3://#{bucket}", params: ["list-type": 2, prefix: "#{pre}/l/5", "max-keys": 2], decode_body: true)
IO.puts("P6 list one: #{inspect(r3.body)}")
r4 = Req.get!(req, url: "s3://#{bucket}", params: ["list-type": 2, prefix: "#{pre}/none/", "max-keys": 2], decode_body: true)
IO.puts("P6 list none: #{inspect(r4.body)}")
bad = Req.new(retry: false, aws_sigv4: Keyword.put(sigv4, :secret_access_key, "wrong-secret-0123456789"), decode_body: false) |> ReqS3.attach(aws_endpoint_url_s3: url)
show.("P7 wrong secret put", Req.put!(bad, url: "s3://#{bucket}/#{pre}/c", body: data))
show.("P7b wrong secret head", Req.head!(bad, url: "s3://#{bucket}/#{pre}/a"))
p = ReqS3.presign_url(access_key_id: ak, secret_access_key: sk, region: region, endpoint_url: url, bucket: bucket, key: "#{pre}/a", expires: 1)
IO.puts("P8 presign contains ak? #{String.contains?(p, ak)} sk? #{String.contains?(p, sk)}")
show.("P8 presigned get now", Req.get!(p, retry: false))
Process.sleep(2100)
show.("P8b presigned get after 2.1s", Req.get!(p, retry: false))
show.("P9 delete missing", Req.delete!(req, url: "s3://#{bucket}/#{pre}/missing"))
show.("P9b delete missing bucket", Req.delete!(req, url: "s3://no-such-bucket-elz/#{pre}/a"))
show.("P9c delete existing", Req.delete!(req, url: "s3://#{bucket}/#{pre}/a"))
big = String.duplicate("z", 100_000)
stream = Stream.unfold(big, fn "" -> nil; s -> String.split_at(s, 10_000) end)
show.("P10 stream put right checksum", Req.put!(req, url: "s3://#{bucket}/#{pre}/s", body: stream, headers: [{"content-length", "100000"}, {"x-amz-checksum-sha256", b64.(big)}]))
show.("P10b stream put wrong checksum", Req.put!(req, url: "s3://#{bucket}/#{pre}/s2", body: stream, headers: [{"content-length", "100000"}, {"x-amz-checksum-sha256", b64.("no")}]))
show.("P10c head s2", Req.head!(req, url: "s3://#{bucket}/#{pre}/s2"))
show.("P11 if-none-match existing", Req.put!(req, url: "s3://#{bucket}/#{pre}/s", body: "x", headers: [{"if-none-match", "*"}]))
show.("P11b if-none-match new", Req.put!(req, url: "s3://#{bucket}/#{pre}/n", body: "x", headers: [{"if-none-match", "*"}]))
show.("P12 invalid key (empty seg)", Req.put!(req, url: "s3://#{bucket}/#{pre}//x/../y", body: "x"))
System.put_env("AWS_ACCESS_KEY_ID", "envkey"); System.put_env("AWS_SECRET_ACCESS_KEY", "envsecret"); System.put_env("AWS_ENDPOINT_URL_S3", "http://127.0.0.1:1")
show.("P13 explicit options beat env", Req.head!(req, url: "s3://#{bucket}/#{pre}/s"))
IO.puts("P14 inspect req contains sk? #{String.contains?(inspect(req, limit: :infinity, printable_limit: :infinity), sk)}")
e = try do Req.put!(Req.merge(req, aws_endpoint_url_s3: "http://127.0.0.1:1"), url: "s3://#{bucket}/x", body: "x") rescue e -> e end
IO.puts("P15 refused exception: #{inspect(e.__struct__)} #{inspect(Map.get(e, :reason))} contains sk? #{String.contains?(inspect(e, limit: :infinity), sk)}")
