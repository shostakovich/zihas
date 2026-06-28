# frozen_string_literal: true

require "test_helper"

class Lights::ToastComponentTest < ViewComponent::TestCase
  test "hidden and empty without a message" do
    rendered = render_inline(Lights::ToastComponent.new(message: nil, undo: nil))
    assert rendered.css("div#light_toast[hidden]").any?
    assert rendered.css("button").none?
  end

  test "shows the message and an undo button" do
    undo = { light_key: "K1", victim: "sideLightToggle", added: "bottomLightToggle" }
    rendered = render_inline(Lights::ToastComponent.new(message: "Seite ausgeschaltet", undo: undo))

    assert rendered.css("div#light_toast[hidden]").none?
    assert_includes rendered.to_html, "Seite ausgeschaltet"
    assert_includes rendered.to_html, "Rückgängig"
  end
end
