$LOAD_PATH.unshift File.expand_path("lib", __dir__)
$LOAD_PATH.unshift File.expand_path("app", __dir__)

require "ziwoas"
require "web"

$ZIWOAS_APP = Ziwoas::App.boot

at_exit { $ZIWOAS_APP.stop! rescue nil }

run Web
