# test/govees/subscriber_test.rb
require "test_helper"
require "govees/subscriber"

class GoveesSubscriberConfigTest < ActiveSupport::TestCase
  setup do
    Light.delete_all
    @sub = Govees::Subscriber.new(logger: Logger.new(IO::NULL))
  end

  test "subscribes to and matches govees config topics" do
    assert_includes @sub.subscriptions, "govees/+/config"
    assert @sub.matches?("govees/14ABDB4844064B60/config")
  end

  test "config upserts a Light with sku, capabilities, scenes and zones" do
    @sub.handle("govees/K1/config", JSON.generate(
      "sku" => "H60B0", "name" => "Uplighter", "supports_color" => true,
      "supports_color_temp" => true, "zones" => [ "rippleLightToggle" ], "scenes" => [ "Sunset" ]))
    l = Light.find_by(key: "K1")
    assert_equal "H60B0", l.sku
    assert_equal "Uplighter", l.name
    assert l.supports_color
    assert_equal [ "rippleLightToggle" ], l.zones
    assert_equal [ "Sunset" ], l.firmware_scenes
  end

  test "user rename is preserved on later config" do
    Light.create!(key: "K1", name: "Mein Name", zones: [])
    @sub.handle("govees/K1/config", JSON.generate("sku" => "H60B0", "name" => "Uplighter", "zones" => [], "scenes" => []))
    assert_equal "Mein Name", Light.find_by(key: "K1").name
  end

  test "config ignores invalid JSON" do
    assert_nothing_raised { @sub.handle("govees/K1/config", "x{") }
    assert_equal 0, Light.count
  end
end
