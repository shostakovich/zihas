require "test_helper"

class LightMoodTest < ActiveSupport::TestCase
  test "ALL contains the four curated moods with stable ids" do
    assert_equal %w[sunset reading cinema party], LightMood::ALL.map(&:id)
  end

  test "every mood is renderable and applies exactly one colour mode" do
    LightMood::ALL.each do |m|
      assert m.name.present?, "#{m.id} needs a name"
      assert m.emoji.present?, "#{m.id} needs an emoji"
      assert m.gradient.start_with?("linear-gradient"), "#{m.id} needs a preview gradient"
      assert m.brightness.is_a?(Integer)
      assert m.color.nil? ^ m.color_temp_k.nil?, "#{m.id} must set color XOR color_temp_k"
    end
  end

  test "reading is a warm-white mood" do
    m = LightMood.find("reading")
    assert_nil m.color
    assert_equal 3000, m.color_temp_k
  end

  test "find returns nil for an unknown id" do
    assert_nil LightMood.find("nope")
  end
end
