// SPDX-License-Identifier: Apache-2.0
import gleam/int
import gleam/result

pub opaque type Model {
  Model(value: Int)
}

pub type Message {
  Increment
  Decrement
  Replace(Model)
}

pub fn initial() -> Model {
  Model(0)
}

pub fn value(model: Model) -> Int {
  model.value
}

pub fn from_attribute(text: String) -> Result(Model, Nil) {
  use number <- result.try(int.parse(text))
  case number >= 0 && number <= 100 {
    True -> Ok(Model(number))
    False -> Error(Nil)
  }
}

pub fn update(model: Model, message: Message) -> Model {
  case message {
    Increment -> Model(int.min(model.value + 1, 100))
    Decrement -> Model(int.max(model.value - 1, 0))
    Replace(next) -> next
  }
}
