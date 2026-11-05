// SPDX-License-Identifier: Apache-2.0
import gleam/list
import gleeunit
import gleeunit/should
import quantity

pub fn main() {
  gleeunit.main()
}

pub fn repeated_clicks_preserve_bounds_test() {
  let maximum =
    list.repeat(quantity.Increment, 1000)
    |> list.fold(quantity.initial(), quantity.update)
  quantity.value(maximum) |> should.equal(100)
  list.repeat(quantity.Decrement, 1000)
  |> list.fold(maximum, quantity.update)
  |> quantity.value
  |> should.equal(0)
}

pub fn host_attribute_is_validated_test() {
  list.each(["-1", "101", "1.5", "", "<script>", "NaN"], fn(text) {
    quantity.from_attribute(text) |> should.equal(Error(Nil))
  })
  let assert Ok(maximum) = quantity.from_attribute("100")
  quantity.value(maximum) |> should.equal(100)
}

pub fn host_replacement_and_user_edits_compose_test() {
  let assert Ok(replacement) = quantity.from_attribute("42")
  quantity.initial()
  |> quantity.update(quantity.Replace(replacement))
  |> quantity.update(quantity.Increment)
  |> quantity.update(quantity.Decrement)
  |> quantity.value
  |> should.equal(42)
}
