require "test_helper"

class DashboardControllerTest < ActionDispatch::IntegrationTest
  test "energy flow node contents are vertically centered in circles" do
    get "/"
    assert_response :ok

    assert_select "text[data-dashboard-target='efPvW'][x='200'][y='102'][text-anchor='middle']", 1

    assert_select "image[x='42'][y='150'][width='32'][height='32']", 1
    assert_select "text[data-dashboard-target='efGridW'][x='58'][y='197'][text-anchor='middle']", 1

    assert_select "image[x='326'][y='150'][width='32'][height='32']", 1
    assert_select "text[data-dashboard-target='efConsumerW'][x='342'][y='197'][text-anchor='middle']", 1
  end

  test "uses current weather icon in hero and pv energy flow node" do
    WeatherRecord.delete_all
    WeatherRecord.create!(kind: "current", lat: 52.52, lon: 13.405, timestamp: Time.zone.parse("2026-05-04 12:00"), daytime: "night", icon: "cloudy")

    get "/"
    assert_response :ok

    assert_select "img.hero-icon[src*='weather_cloudy_night']", 1
    assert_select "image[href*='weather_cloudy_night'][x='184'][y='55'][width='32'][height='32']", 1
  end

  test "falls back to sun icon without current weather" do
    WeatherRecord.delete_all

    get "/"
    assert_response :ok

    assert_select "img.hero-icon[src*='icon_sonne']", 1
    assert_select "image[href*='icon_sonne'][x='184'][y='55'][width='32'][height='32']", 1
  end
end
