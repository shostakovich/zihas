require "simplecov"
SimpleCov.start "rails" do
  enable_coverage :branch
  minimum_coverage line: 70, branch: 71
end

ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "minitest/mock"
require "webmock/minitest"
WebMock.disable_net_connect!(allow_localhost: true)

require "vcr"
require "govees/cassette_scrubber"

VCR.configure do |c|
  c.cassette_library_dir = "test/vcr_cassettes"
  c.hook_into :webmock
  c.ignore_localhost = true                                   # Cuprite/Capybara-Server (127.0.0.1) nicht abfangen
  c.default_cassette_options = { record: :none }              # CI/normal: nur abspielen
  c.allow_http_connections_when_no_cassette = false
  c.filter_sensitive_data("<GOVEE_API_KEY>") { Govees::CassetteScrubber.api_key }
  c.before_record { |i| Govees::CassetteScrubber.scrub!(i) }
end

module ActiveSupport
  class TestCase
    parallelize(workers: 1)
    fixtures :all

    teardown { ConfigLoader.reset_app_config! }
  end
end
