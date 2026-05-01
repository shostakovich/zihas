require "simplecov"
SimpleCov.start "rails" do
  enable_coverage :branch
  minimum_coverage line: 38, branch: 4
end

ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "webmock/minitest"

module ActiveSupport
  class TestCase
    parallelize(workers: 1)
    fixtures :all
  end
end
