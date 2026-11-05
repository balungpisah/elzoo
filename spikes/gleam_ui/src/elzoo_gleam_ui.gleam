// SPDX-License-Identifier: Apache-2.0
import gleam/int
import gleam/json
import gleam/result
import lustre
import lustre/attribute
import lustre/component
import lustre/effect
import lustre/element/html
import lustre/event
import quantity

pub fn main() {
  let app =
    lustre.component(
      fn(_) { #(quantity.initial(), effect.none()) },
      update,
      view,
      [
        component.on_attribute_change("value", fn(text) {
          quantity.from_attribute(text) |> result.map(quantity.Replace)
        }),
      ],
    )
  let assert Ok(_) = lustre.register(app, "elzoo-quantity")
  Nil
}

fn update(model, message) {
  let next = quantity.update(model, message)
  let changed = quantity.value(next) != quantity.value(model)
  let notification = case message, changed {
    quantity.Replace(_), _ -> effect.none()
    _, False -> effect.none()
    _, True ->
      event.emit(
        "quantity-change",
        json.object([
          #("value", json.int(quantity.value(next))),
        ]),
      )
  }
  #(next, notification)
}

fn view(model) {
  let count = quantity.value(model)
  html.div([attribute.role("group"), attribute.aria_label("Quantity")], [
    html.button(
      [
        attribute.type_("button"),
        attribute.aria_label("Decrease quantity"),
        attribute.disabled(count == 0),
        event.on_click(quantity.Decrement),
      ],
      [html.text("−")],
    ),
    html.output([attribute.aria_live("polite")], [
      html.text(int.to_string(count)),
    ]),
    html.button(
      [
        attribute.type_("button"),
        attribute.aria_label("Increase quantity"),
        attribute.disabled(count == 100),
        event.on_click(quantity.Increment),
      ],
      [html.text("+")],
    ),
  ])
}
