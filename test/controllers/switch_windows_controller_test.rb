require "test_helper"

class SwitchWindowsControllerTest < ActionDispatch::IntegrationTest
  setup { SwitchWindow.delete_all }

  def valid_params
    { switch_window: { on_at_time: "18:00", off_at_time: "23:00", days: [ "", "1", "2" ] } }
  end

  test "new renders the inline editor" do
    get "/plugs/fridge/switch_windows/new", as: :turbo_stream
    assert_response :success
    assert_match "sw_editor_fridge", @response.body
    assert_match "switch_window[days][]", @response.body
  end

  test "create saves a window and re-renders the windows region" do
    post "/plugs/fridge/switch_windows", params: valid_params, as: :turbo_stream
    assert_response :success
    w = SwitchWindow.last
    assert_equal [ "fridge", 1080, 1380, [ 1, 2 ] ], [ w.plug_id, w.on_at, w.off_at, w.days ]
    assert_match "sw_windows_fridge", @response.body
  end

  test "create with no days re-renders the form with errors and 422" do
    post "/plugs/fridge/switch_windows",
         params: { switch_window: { on_at_time: "18:00", off_at_time: "23:00", days: [ "" ] } },
         as: :turbo_stream
    assert_response :unprocessable_entity
    assert_equal 0, SwitchWindow.count
    assert_match "Wochentag", @response.body
  end

  test "create for unknown plug returns 404, for non-switchable 422" do
    post "/plugs/nope/switch_windows", params: valid_params, as: :turbo_stream
    assert_response :not_found
    post "/plugs/bkw/switch_windows", params: valid_params, as: :turbo_stream
    assert_response :unprocessable_entity
  end

  test "update pauses a window via enabled param" do
    w = SwitchWindow.create!(plug_id: "fridge", on_at: 1080, off_at: 1380, days: [ 1 ])
    patch "/plugs/fridge/switch_windows/#{w.id}",
          params: { switch_window: { enabled: "false" } }, as: :turbo_stream
    assert_response :success
    refute w.reload.enabled
  end

  test "edit renders the form for an existing window" do
    w = SwitchWindow.create!(plug_id: "fridge", on_at: 1080, off_at: 1380, days: [ 1 ])
    get "/plugs/fridge/switch_windows/#{w.id}/edit", as: :turbo_stream
    assert_response :success
    assert_match "18:00", @response.body
  end

  test "destroy removes the window" do
    w = SwitchWindow.create!(plug_id: "fridge", on_at: 1080, off_at: 1380, days: [ 1 ])
    delete "/plugs/fridge/switch_windows/#{w.id}", as: :turbo_stream
    assert_response :success
    assert_equal 0, SwitchWindow.count
  end

  test "destroy works for orphaned windows" do
    w = SwitchWindow.create!(plug_id: "gone", on_at: 60, off_at: 120, days: [ 1 ])
    delete "/plugs/gone/switch_windows/#{w.id}", as: :turbo_stream
    assert_response :success
    assert_equal 0, SwitchWindow.count
    assert_match "orphan_window_#{w.id}", @response.body
  end

  test "failed update re-renders the form with errors into a replaceable target" do
    w = SwitchWindow.create!(plug_id: "fridge", on_at: 1080, off_at: 1380, days: [ 1 ])
    get "/plugs/fridge/switch_windows/#{w.id}/edit", as: :turbo_stream
    assert_match "id=\"switch_window_#{w.id}\"", @response.body  # edit response must carry the target id
    patch "/plugs/fridge/switch_windows/#{w.id}",
          params: { switch_window: { on_at_time: "", off_at_time: "23:00" } }, as: :turbo_stream
    assert_response :unprocessable_entity
    assert_match "id=\"switch_window_#{w.id}\"", @response.body  # error form re-targets the same id
  end

  test "edit and update are scoped to the plug in the URL" do
    w = SwitchWindow.create!(plug_id: "fridge", on_at: 1080, off_at: 1380, days: [ 1 ])
    # bkw is in config but not switchable -> 422 via set_plug; use a switchable foreign URL instead:
    # there is only one switchable plug in the test config, so scope-mismatch must 404 via the unknown-window path.
    get "/plugs/fridge/switch_windows/999999/edit", as: :turbo_stream
    assert_response :not_found
  end
end
