ENV["RACK_ENV"] = "test"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift File.expand_path("../app", __dir__)

require "minitest/autorun"
require "webmock/minitest"

WebMock.disable_net_connect!(allow_localhost: true)
