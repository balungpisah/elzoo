# SPDX-License-Identifier: Apache-2.0
# domain/money (ELZ-031): derive the factual ISO 4217 extract from the two SIX
# list files, or check a committed extract against them.
#
#   elixir iso4217_derive.exs LIST_ONE LIST_THREE [--downloaded YYYY-MM-DD]
#   elixir iso4217_derive.exs LIST_ONE LIST_THREE --check EXTRACT
#
# Run with plain `elixir` (OTP :xmerl on the code path); it needs a fresh
# download and is not part of `mix check`. Exit codes: 0 equal (or extract
# printed); 1 a hash difference, a missing hash field or a row difference;
# 2 unreadable input or a parse failure. Only factual fields are extracted:
# no country or currency names.
defmodule Elzoo.Money.ISO4217Derive do
  @base "https://www.six-group.com/dam/download/financial-information/data-center/iso-currrency/lists/"

  def main(args) do
    case args do
      [one, three, "--check", extract] -> check(one, three, extract)
      [one, three, "--downloaded", date] -> IO.write(derive(one, three, date))
      [one, three] -> IO.write(derive(one, three, Date.utc_today() |> Date.to_iso8601()))
      _ -> fail(2, "usage: elixir iso4217_derive.exs LIST_ONE LIST_THREE [--downloaded DATE | --check EXTRACT]")
    end
  end

  def derive(one, three, downloaded) do
    {one_bytes, three_bytes} = {read!(one), read!(three)}

    try do
      derive_bytes(one_bytes, three_bytes, downloaded)
    rescue
      error -> fail(2, "parse failure: #{Exception.message(error)}")
    end
  end

  defp derive_bytes(one_bytes, three_bytes, downloaded) do
    {published1, rows1} = parse(one_bytes, ~c"CcyNtry")
    {published3, rows3} = parse(three_bytes, ~c"HstrcCcyNtry")

    header = [
      "# elzoo domain/money ISO 4217 derived extract, format 1",
      "# Factual fields only (codes, numeric codes, minor units, withdrawal text, fund flag).",
      "# No SIX file is committed. Source attribution: ISO 4217 maintenance agency (SIX Group).",
      "# version\t#{published1}",
      "# current_source\t#{@base}list-one.xml",
      "# current_published\t#{published1}",
      "# current_sha256\t#{sha(one_bytes)}",
      "# historic_source\t#{@base}list-three.xml",
      "# historic_published\t#{published3}",
      "# historic_sha256\t#{sha(three_bytes)}",
      "# downloaded\t#{downloaded}",
      "# columns\ttable\talpha\tnumeric\tminor_unit\twithdrawal\tfund"
    ]

    lines =
      Enum.map(rows1, &row("current", &1)) ++ Enum.map(rows3, &row("historic", &1))

    Enum.join(header ++ lines, "\n") <> "\n"
  end

  defp row(table, fields) do
    Enum.join(
      [
        table,
        fields["Ccy"] || "",
        fields["CcyNbr"] || "",
        fields["CcyMnrUnts"] || "",
        fields["WthdrwlDt"] || "",
        if(fields[:fund], do: "true", else: "false")
      ],
      "\t"
    )
  end

  defp parse(bytes, entry_tag) do
    {doc, _} =
      try do
        :xmerl_scan.string(:binary.bin_to_list(bytes), quiet: true)
      catch
        kind, reason -> fail(2, "parse failure: #{inspect({kind, reason})}")
      end

    published =
      case :xmerl_xpath.string(~c"/ISO_4217/@Pblshd", doc) do
        [{:xmlAttribute, _, _, _, _, _, _, _, value, _}] -> List.to_string(value)
        _ -> fail(2, "missing Pblshd")
      end

    entries = :xmerl_xpath.string(~c"//" ++ entry_tag, doc)
    if entries == [], do: fail(2, "no #{entry_tag} entries")
    {published, Enum.map(entries, &fields/1)}
  end

  defp fields({:xmlElement, _, _, _, _, _, _, _, content, _, _, _}) do
    Enum.reduce(content, %{}, fn
      {:xmlElement, name, _, _, _, _, _, attrs, inner, _, _, _}, acc ->
        text = inner |> Enum.map(fn {:xmlText, _, _, _, v, _} -> List.to_string(v); _ -> "" end) |> Enum.join() |> String.trim()
        fund? = Enum.any?(attrs, fn {:xmlAttribute, :IsFund, _, _, _, _, _, _, v, _} -> List.to_string(v) in ["true", "WAHR"]; _ -> false end)
        acc |> Map.put(Atom.to_string(name), text) |> then(&if(fund?, do: Map.put(&1, :fund, true), else: &1))

      _, acc ->
        acc
    end)
  end

  def check(one, three, extract) do
    {_, _} = {read!(one), read!(three)}
    committed = read!(extract)
    header = header_fields(committed)

    for {field, file} <- [{"current_sha256", one}, {"historic_sha256", three}] do
      case header[field] do
        nil -> fail(1, "extract header lacks #{field}")
        expected -> if expected != sha(read!(file)), do: fail(1, "#{field} differs: extract #{expected}, file #{sha(read!(file))}")
      end
    end

    fresh = derive(one, three, header["downloaded"] || "")
    {old_rows, new_rows} = {rows(committed), rows(fresh)}

    if header_fields(fresh) != header or old_rows != new_rows do
      diff = List.myers_difference(old_rows, new_rows) |> Enum.reject(&match?({:eq, _}, &1))
      IO.puts("DRIFT: header equal? #{header_fields(fresh) == header}; row differences: #{inspect(diff, limit: 20)}")
      System.halt(1)
    end

    IO.puts("EXTRACT MATCHES: #{length(old_rows)} rows; current_sha256 #{header["current_sha256"]}; historic_sha256 #{header["historic_sha256"]}")
  end

  defp header_fields(text) do
    for "# " <> line <- String.split(text, "\n"), [k, v] <- [String.split(line, "\t", parts: 2)], into: %{}, do: {k, v}
  end

  defp rows(text), do: text |> String.split("\n", trim: true) |> Enum.reject(&String.starts_with?(&1, "#"))

  defp read!(path) do
    case File.read(path) do
      {:ok, bytes} -> bytes
      {:error, reason} -> fail(2, "cannot read #{path}: #{reason}")
    end
  end

  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp fail(code, message) do
    IO.puts(:stderr, message)
    System.halt(code)
  end
end

Elzoo.Money.ISO4217Derive.main(System.argv())
