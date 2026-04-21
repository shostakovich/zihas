$LOAD_PATH.unshift File.expand_path("lib", __dir__)
$LOAD_PATH.unshift File.expand_path("app", __dir__)

require "web"
run Web
