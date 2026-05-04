require "test_helper"

class DashboardControllerTest < ActionDispatch::IntegrationTest
  test "energy flow node contents are vertically centered in circles" do
    get "/"
    assert_response :ok

    assert_select "image[x='184'][y='55'][width='32'][height='32']", 1
    assert_select "text[data-dashboard-target='efPvW'][x='200'][y='102'][text-anchor='middle']", 1

    assert_select "image[x='42'][y='150'][width='32'][height='32']", 1
    assert_select "text[data-dashboard-target='efGridW'][x='58'][y='197'][text-anchor='middle']", 1

    assert_select "image[x='326'][y='150'][width='32'][height='32']", 1
    assert_select "text[data-dashboard-target='efConsumerW'][x='342'][y='197'][text-anchor='middle']", 1
  end
end
