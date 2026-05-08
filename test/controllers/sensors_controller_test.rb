# test/controllers/sensors_controller_test.rb
require "test_helper"

class SensorsControllerTest < ActionDispatch::IntegrationTest
  test "GET /sensors returns 200" do
    get "/sensors"
    assert_response :success
  end

  test "GET /sensors/series returns JSON with three series" do
    SensorReading.delete_all
    SensorReading.create!(device_id: "TEST_INDOOR",  taken_at: 30.minutes.ago,
                          temperature: 21.0, humidity: 50, co2: 700, battery_pct: 90)
    SensorReading.create!(device_id: "TEST_OUTDOOR", taken_at: 30.minutes.ago,
                          temperature: 12.0, humidity: 70, battery_pct: 100)

    get "/sensors/series"
    assert_response :success
    body = JSON.parse(@response.body)
    assert body.key?("temperature")
    assert body.key?("humidity")
    assert body.key?("co2")

    indoor_temp = body["temperature"].find { |s| s["device_id"] == "TEST_INDOOR" }
    assert_equal 1, indoor_temp["points"].length
    assert_equal 21.0, indoor_temp["points"][0][1]

    co2_devices = body["co2"].map { |s| s["device_id"] }
    refute_includes co2_devices, "TEST_OUTDOOR"
  end
end
