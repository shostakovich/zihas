require "test_helper"

class SmokeTest < ActiveSupport::TestCase
  test "application boots without error" do
    assert_kind_of Ziwoas::Application, Rails.application
  end

  test "Sample model connects to database" do
    assert_nothing_raised { Sample.count }
  end
end
