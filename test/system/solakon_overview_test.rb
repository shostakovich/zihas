require_relative "application_system_test_case"

class SolakonOverviewTest < ApplicationSystemTestCase
  setup do
    SolakonReading.delete_all
    SolakonSnapshot.delete_all
  end

  test "Solakon page is usable on mobile without fresh data" do
    page.current_window.resize_to(390, 844)

    visit solakon_path

    assert_text "PV"
    # Section/tile labels are uppercased via CSS (text-transform), so the
    # browser reports e.g. "ENERGIEFLUSS" — match case-insensitively.
    assert_text(/Energiefluss/i)
    assert_text "Außensteckdose"
    assert_text "Auto-Regelung"
    assert_text(/Batteriegesundheit/i)
    assert_selector "canvas[data-solakon-target='historyCanvas']"
    assert_no_text "SOH"
    assert_no_text "Modbus"

    chart_box = page.evaluate_script(<<~JS)
      (() => {
        const canvas = document.querySelector("canvas[data-solakon-target='historyCanvas']");
        const rect = canvas.getBoundingClientRect();
        return { width: rect.width, height: rect.height };
      })();
    JS

    assert_operator chart_box.fetch("width"), :>, 250
    assert_operator chart_box.fetch("height"), :>, 180
  end
end
