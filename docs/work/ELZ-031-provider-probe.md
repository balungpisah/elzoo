# ELZ-031 provider probe: ex_money 6.3.0 versus Decimal 3.2.0

Run 2026-11-08 (UTC) in a scratch Mix project outside the repository, Elixir 1.20.4 / OTP 29.1.2.
Dependencies: `{:ex_money, "== 6.3.0"}`, `{:decimal, "== 3.2.0"}`, `{:jason, "~> 1.4"}`; resolved
ex_money 6.3.0, localize 1.6.1, gettext 1.0.2, expo 1.1.1, nimble_parsec 1.4.2, decimal 3.2.0,
jason 1.4.5. No configuration (ex_money 6 removed the Cldr backend). Observations only; the
decision and its reasons are in `ELZ-031.md` section 2.

## Probe script (`mix run probe.exs`)

```elixir
IO.puts("ex_money #{Application.spec(:ex_money, :vsn)} localize #{Application.spec(:localize, :vsn)} decimal #{Application.spec(:decimal, :vsn)}")
show = fn label, fun ->
  result = try do fun.() rescue e -> {:raised, e.__struct__, Exception.message(e)} end
  IO.puts("#{label} => #{inspect(result, limit: :infinity)}")
end
IO.puts("--- A. construction from untrusted strings")
for {c, a} <- [{"EUR", "1.00"}, {"eur", "1.00"}, {" EUR", "1.00"}, {"EU", "1"}, {"EURO", "1"}, {"E$R", "1"}, {"XYZ", "1"}, {"978", "1"}, {"HRK", "1"}, {"XAU", "1"}, {"XXX", "1"}, {"EUR", "1.005"}, {"JPY", "1.5"}, {"BHD", "1.2345"}, {"EUR", "abc"}, {"EUR", "1e3"}, {"EUR", "1,00"}, {"EUR", "-1.00"}, {"EUR", "+1.00"}, {"EUR", " 1.00 "}, {"EUR", ""}] do
  show.("new(#{inspect c}, #{inspect a})", fn -> Money.new(c, a) end)
end
show.("new(:EUR, 1.5 float)", fn -> Money.new(:EUR, 1.5) end)
show.("new(\"EUR\", 1.5 float)", fn -> Money.new("EUR", 1.5) end)
show.("from_float(:EUR, 1.005)", fn -> Money.from_float(:EUR, 1.005) end)
show.("parse(\"EUR 1.00\")", fn -> Money.parse("EUR 1.00") end)
show.("parse(\"1.00 euros\")", fn -> Money.parse("1.00 euros") end)
show.("parse(\"€1.00\")", fn -> Money.parse("€1.00") end)
IO.puts("--- B. allocation residuals")
show.("split(EUR 1.00, 3)", fn -> Money.split(Money.new(:EUR, "1.00"), 3) end)
show.("split(EUR 1.00, 3) sum check", fn -> {d, r} = Money.split(Money.new(:EUR, "1.00"), 3); Money.add!(Money.mult!(d, 3), r) end)
show.("split(JPY 1000, 3)", fn -> Money.split(Money.new(:JPY, 1000), 3) end)
show.("split(BHD 1.234, 3)", fn -> Money.split(Money.new(:BHD, "1.234"), 3) end)
show.("split(EUR 0.05, 3)", fn -> Money.split(Money.new(:EUR, "0.05"), 3) end)
show.("split(EUR -1.00, 3)", fn -> Money.split(Money.new(:EUR, "-1.00"), 3) end)
show.("mult(EUR 1.00, Decimal 1/3)", fn -> Money.mult(Money.new(:EUR, "1.00"), Decimal.div(1, 3)) end)
show.("mult(EUR 1.00, 0.3333 float)", fn -> Money.mult(Money.new(:EUR, "1.00"), 0.3333) end)
show.("div(EUR 1.00, 3)", fn -> Money.div(Money.new(:EUR, "1.00"), 3) end)
show.("ratio allocation API?", fn -> {function_exported?(Money, :allocate, 2), function_exported?(Money, :split, 3), Money.__info__(:functions) |> Enum.filter(fn {n, _} -> n in [:allocate, :split, :round, :to_integer_exp, :from_integer, :to_decimal, :cmp, :compare, :equal?, :add, :sub, :mult, :div, :abs, :negate, :zero?, :positive?, :negative?, :known_currencies] end)} end)
IO.puts("--- C. 0- and 3-exponent currencies")
show.("JPY 1000 to_string", fn -> Money.to_string(Money.new(:JPY, 1000)) end)
show.("JPY 1000 to_integer_exp", fn -> Money.to_integer_exp(Money.new(:JPY, 1000)) end)
show.("JPY 1000.5 to_integer_exp", fn -> Money.to_integer_exp(Money.new(:JPY, "1000.5")) end)
show.("BHD 1.234 to_string", fn -> Money.to_string(Money.new(:BHD, "1.234")) end)
show.("BHD 1.234 to_integer_exp", fn -> Money.to_integer_exp(Money.new(:BHD, "1.234")) end)
show.("BHD 1.2345 round", fn -> Money.round(Money.new(:BHD, "1.2345")) end)
show.("EUR 1.005 round default", fn -> Money.round(Money.new(:EUR, "1.005")) end)
show.("EUR 1.005 round half_even", fn -> Money.round(Money.new(:EUR, "1.005"), rounding_mode: :half_even) end)
show.("EUR 1.005 round half_up", fn -> Money.round(Money.new(:EUR, "1.005"), rounding_mode: :half_up) end)
show.("from_integer(100, :EUR)", fn -> Money.from_integer(100, :EUR) end)
show.("from_integer(1000, :JPY)", fn -> Money.from_integer(1000, :JPY) end)
show.("from_integer(1234, :BHD)", fn -> Money.from_integer(1234, :BHD) end)
show.("from_integer(1, :XAU)", fn -> Money.from_integer(1, :XAU) end)
show.("from_integer(100, :HRK)", fn -> Money.from_integer(100, :HRK) end)
show.("CLF 4 digits", fn -> {Money.from_integer(12345, :CLF), Money.to_integer_exp(Money.new(:CLF, "1.2345"))} end)
show.("UYW 4 digits", fn -> Money.to_integer_exp(Money.new(:UYW, "1.2345")) end)
show.("digits EUR JPY BHD CLF XAU HRK", fn -> for c <- [:EUR, :JPY, :BHD, :CLF, :XAU, :HRK, :ZWL, :ZWG, :SLE, :VED, :ANG, :XCG], do: {c, (case Money.Currency.currency_for_code(c) do {:ok, cur} -> {cur.iso_digits, cur.digits, cur.to} ; e -> e end)} end)
IO.puts("--- D. currency mismatch and persistence")
show.("add(EUR, USD)", fn -> Money.add(Money.new(:EUR, 1), Money.new(:USD, 1)) end)
show.("compare(EUR, USD)", fn -> Money.compare(Money.new(:EUR, 1), Money.new(:USD, 1)) end)
show.("Jason encode", fn -> Jason.encode!(Money.new(:BHD, "1.234")) end)
show.("Jason decode roundtrip manual", fn -> m = Jason.decode!(Jason.encode!(Money.new(:BHD, "1.234"))); Money.new(m["currency"], m["amount"]) end)
show.("Jason encode JPY 1000", fn -> Jason.encode!(Money.new(:JPY, 1000)) end)
show.("Jason encode EUR 1.0", fn -> Jason.encode!(Money.new(:EUR, "1.0")) end)
show.("equal? EUR 1.0 vs 1.00", fn -> {Money.equal?(Money.new(:EUR, "1.0"), Money.new(:EUR, "1.00")), Money.new(:EUR, "1.0") == Money.new(:EUR, "1.00")} end)
show.("known_current_currencies count", fn -> {length(Money.Currency.known_current_currencies()), length(Money.Currency.known_historic_currencies())} end)
show.("currency data version?", fn -> {Application.spec(:localize, :vsn), Code.ensure_loaded?(Localize.Currency) and function_exported?(Localize, :version, 0) and Localize.version()} end)
show.("HRK in current?", fn -> {:HRK in Money.Currency.known_current_currencies(), :HRK in Money.Currency.known_historic_currencies(), :ZWL in Money.Currency.known_current_currencies(), :ZWG in Money.Currency.known_current_currencies(), :XCG in Money.Currency.known_current_currencies(), :ANG in Money.Currency.known_current_currencies()} end)
```

## Output

```text

21:33:22.835 [warning] [ex_money] Automatically starting the exchange rate service is deprecated. Set `auto_start_exchange_rate_service: false` and, if you use the service, add `Money.ExchangeRates.Retriever` to your supervision tree.
ex_money 6.3.0 localize 1.6.1 decimal 3.2.0
--- A. construction from untrusted strings
new("EUR", "1.00") => Money.new(:EUR, "1.00")
new("eur", "1.00") => Money.new(:EUR, "1.00")
new(" EUR", "1.00") => {:error, {Money.UnknownCurrencyError, "The currency \" EUR\" is not known."}}
new("EU", "1") => {:error, {Money.UnknownCurrencyError, "The currency \"EU\" is not known."}}
new("EURO", "1") => {:error, {Money.UnknownCurrencyError, "The currency \"EURO\" is not known."}}
new("E$R", "1") => {:error, {Money.UnknownCurrencyError, "The currency \"E$R\" is not known."}}
new("XYZ", "1") => {:error, {Money.UnknownCurrencyError, "The currency \"XYZ\" is not known."}}
new("978", "1") => {:error, {Money.UnknownCurrencyError, "The currency \"1\" is not known."}}
new("HRK", "1") => Money.new(:HRK, "1")
new("XAU", "1") => Money.new(:XAU, "1")
new("XXX", "1") => Money.new(:XXX, "1")
new("EUR", "1.005") => Money.new(:EUR, "1.005")
new("JPY", "1.5") => Money.new(:JPY, "1.5")
new("BHD", "1.2345") => Money.new(:BHD, "1.2345")
new("EUR", "abc") => {:error, {Money.Invalid, "Unable to create money from \"EUR\" and \"abc\""}}
new("EUR", "1e3") => Money.new(:EUR, "1E+3")
new("EUR", "1,00") => {:error, {Money.Invalid, "Unable to create money from \"EUR\" and \"1,00\""}}
new("EUR", "-1.00") => Money.new(:EUR, "-1.00")
new("EUR", "+1.00") => Money.new(:EUR, "1.00")
new("EUR", " 1.00 ") => Money.new(:EUR, "1.00")
new("EUR", "") => {:error, {Money.Invalid, "Unable to create money from \"EUR\" and \"\""}}
new(:EUR, 1.5 float) => {:error, {Money.InvalidAmountError, "Float amounts are not supported in new/2 due to potential rounding and precision issues.  If absolutely required, use Money.from_float/2"}}
new("EUR", 1.5 float) => {:error, {Money.InvalidAmountError, "Float amounts are not supported in new/2 due to potential rounding and precision issues.  If absolutely required, use Money.from_float/2"}}
from_float(:EUR, 1.005) => Money.new(:EUR, "1.005")
parse("EUR 1.00") => Money.new(:EUR, "1.00")
parse("1.00 euros") => Money.new(:EUR, "1.00")
parse("€1.00") => Money.new(:EUR, "1.00")
--- B. allocation residuals
split(EUR 1.00, 3) => {Money.new(:EUR, "0.33"), Money.new(:EUR, "0.01")}
split(EUR 1.00, 3) sum check => Money.new(:EUR, "1.00")
split(JPY 1000, 3) => {Money.new(:JPY, "333"), Money.new(:JPY, "1")}
split(BHD 1.234, 3) => {Money.new(:BHD, "0.411"), Money.new(:BHD, "0.001")}
split(EUR 0.05, 3) => {Money.new(:EUR, "0.01"), Money.new(:EUR, "0.02")}
split(EUR -1.00, 3) => {Money.new(:EUR, "-0.33"), Money.new(:EUR, "-0.01")}
mult(EUR 1.00, Decimal 1/3) => {:ok, Money.new(:EUR, "0.3333333333333333333333333333333333")}
mult(EUR 1.00, 0.3333 float) => {:ok, Money.new(:EUR, "0.333300")}
div(EUR 1.00, 3) => {:ok, Money.new(:EUR, "0.3333333333333333333333333333333333")}
ratio allocation API? => {false, true, [abs: 1, add: 2, cmp: 2, compare: 2, div: 2, equal?: 2, from_integer: 1, from_integer: 2, from_integer: 3, known_currencies: 0, mult: 2, negate: 1, negative?: 1, positive?: 1, round: 1, round: 2, split: 2, split: 3, sub: 2, to_decimal: 1, to_integer_exp: 1, to_integer_exp: 2, zero?: 1]}
--- C. 0- and 3-exponent currencies
JPY 1000 to_string => {:ok, "¥1,000"}
JPY 1000 to_integer_exp => {:JPY, 1000, 0, Money.new(:JPY, "0")}
JPY 1000.5 to_integer_exp => {:JPY, 1000, 0, Money.new(:JPY, "0.5")}
BHD 1.234 to_string => {:ok, "BHD\u00A01.234"}
BHD 1.234 to_integer_exp => {:BHD, 1234, -3, Money.new(:BHD, "0.000")}
BHD 1.2345 round => Money.new(:BHD, "1.234")
EUR 1.005 round default => Money.new(:EUR, "1.00")
EUR 1.005 round half_even => Money.new(:EUR, "1.00")
EUR 1.005 round half_up => Money.new(:EUR, "1.01")
from_integer(100, :EUR) => Money.new(:EUR, "1.00")
from_integer(1000, :JPY) => Money.new(:JPY, "1000")
from_integer(1234, :BHD) => Money.new(:BHD, "1.234")
from_integer(1, :XAU) => Money.new(:XAU, "1")
from_integer(100, :HRK) => Money.new(:HRK, "1.00")
CLF 4 digits => {Money.new(:CLF, "1.2345"), {:CLF, 12345, -4, Money.new(:CLF, "0.0000")}}
UYW 4 digits => {:UYW, 12345, -4, Money.new(:UYW, "0.0000")}
digits EUR JPY BHD CLF XAU HRK => [EUR: {2, 2, nil}, JPY: {0, 0, nil}, BHD: {3, 3, nil}, CLF: {4, 4, nil}, XAU: {0, 2, nil}, HRK: {nil, 2, nil}, ZWL: {nil, 2, nil}, ZWG: {2, 2, nil}, SLE: {2, 2, nil}, VED: {2, 2, nil}, ANG: {nil, 2, nil}, XCG: {2, 2, nil}]
--- D. currency mismatch and persistence
add(EUR, USD) => {:error, {ArgumentError, "Cannot add monies with different currencies. Received :EUR and :USD."}}
compare(EUR, USD) => {:error, {ArgumentError, "Cannot compare monies with different currencies. Received :EUR and :USD."}}
Jason encode => "{\"currency\":\"BHD\",\"amount\":\"1.234\"}"
Jason decode roundtrip manual => Money.new(:BHD, "1.234")
Jason encode JPY 1000 => "{\"currency\":\"JPY\",\"amount\":\"1000\"}"
Jason encode EUR 1.0 => "{\"currency\":\"EUR\",\"amount\":\"1.0\"}"
equal? EUR 1.0 vs 1.00 => {true, false}
known_current_currencies count => {177, 129}
currency data version? => {~c"1.6.1", %Version{major: 49, minor: 0, patch: 0}}
HRK in current? => {false, true, false, true, true, false}
```
