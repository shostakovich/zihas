require "test_helper"

class ReportsControllerTest < ActionDispatch::IntegrationTest
  setup do
    DailyTotal.delete_all
    DailyEnergySummary.delete_all
  end

  test "reports page renders" do
    get "/reports"

    assert_response :success
    assert_select "h1", text: "Berichte", count: 1
    assert_select "section.report-controls[aria-label='Zeitraum']", 1
  end

  test "reports page accepts custom range params" do
    get "/reports", params: { start_date: "2026-04-01", end_date: "2026-04-07" }

    assert_response :success
    assert_select "input[name='start_date'][value='2026-04-01']"
    assert_select "input[name='end_date'][value='2026-04-07']"
  end

  test "reports page renders summary ranking and chart payload" do
    DailyTotal.create!(plug_id: "bkw", date: "2026-04-10", energy_wh: 2000)

    get "/reports"

    assert_response :success
    assert_select ".tiles .tile", 8
    labels = css_select(".tiles .tile .tile-label").map { |node| node.text.squish }
    assert_equal [ "Ertrag", "Verbrauch", "Gespart", "Bilanz", "Autarkie", "Eigenverbrauch", "Ø Ertrag/Tag", "Ø Verbrauch/Tag" ], labels
    assert_select ".section-label", text: "Zeitraum", count: 0
    assert_select ".section-label", text: "Zusammenfassung", count: 0
    assert_select ".section-label", text: "Steckdosen"
    assert_select ".section-label", text: "Energie — Ertrag / Verbrauch"
    assert_select ".section-label", text: /Leistung/
    assert_select ".chart-card .chart-frame", minimum: 2
    assert_select ".report-ranking .report-ranking-row", minimum: 1
    assert_select "[data-energy-report-target='dailyCanvas']", 1
    assert_select "[data-energy-report-target='detailCanvas']", 1
    assert_select "script[data-energy-report-target='payload']", 1
  end

  test "reports page orders widgets like the dashboard" do
    DailyTotal.create!(plug_id: "bkw", date: "2026-04-10", energy_wh: 2000)

    get "/reports"

    labels = css_select(".section-label").map { |node| node.text.squish }
    assert_equal "Steckdosen", labels[0]
    assert_match(/\AEnergie/, labels[1])
    assert_match(/\ALeistung/, labels[2])
    assert_match(/\AAutarkie/, labels[3])
  end

  test "reports page describes the power chart resolution" do
    30.times do |i|
      DailyTotal.create!(plug_id: "bkw", date: (Date.new(2026, 4, 1) + i).to_s, energy_wh: 2000)
    end

    get "/reports", params: { preset: "last_30" }

    assert_response :success
    assert_select ".section-label", text: /Leistung — Tagesmittel/
  end

  test "reports page shows empty state without data" do
    get "/reports"

    assert_response :success
    assert_select ".empty-state", text: /Noch keine Berichtsdaten/
  end

  test "layout includes accessible navigation labels and decorative plush icons" do
    get "/reports"

    assert_response :success
    assert_no_match %r{href="/app\.css}, response.body
    assert_select "link[href^='/assets/application'][data-turbo-track='reload']", 1
    assert_select "header.app-header", 1
    assert_select ".app-brand img[alt='Ziwoas — Startseite']", 1

    expected_links = {
      root_path => [ "Home", "nav_dashboard_plush.webp" ],
      switches_path => [ "Schalten", "nav_switches_plush.webp" ],
      reports_path => [ "Berichte", "nav_reports_plush.webp" ],
      weather_path => [ "Wetter", "nav_weather_plush.webp" ],
      sensors_path => [ "Sensoren", "nav_sensors_plush.webp" ]
    }

    expected_links.each do |path, (label, icon)|
      # Propshaft digests asset filenames (nav_dashboard_plush-<digest>.webp),
      # so match the digest-tolerant basename rather than the literal filename.
      icon_basename = File.basename(icon, ".webp")
      assert_select "nav.app-nav a[href='#{path}']" do
        assert_select ".app-nav-label", text: label, count: 1
        assert_select "img.app-nav-icon[alt=''][aria-hidden='true'][src*='#{icon_basename}']", count: 1
      end
    end

    stylesheet = Rails.root.join("app/assets/stylesheets/application.css").read
    assert_includes stylesheet, ".app-nav-icon"
    assert_includes stylesheet, "display: none;"
    assert_includes stylesheet, ".app-nav-label"

    assert_includes stylesheet, "@media (max-width: 640px)"
    assert_includes stylesheet, "bottom: calc(14px + env(safe-area-inset-bottom));"
    assert_includes stylesheet, "backdrop-filter: blur(40px) saturate(1.8);"
    assert_includes stylesheet, "grid-template-columns: repeat(5, minmax(0, 1fr));"
    assert_includes stylesheet, "width: 32px;"
    assert_includes stylesheet, "font-weight: 500;"
  end

  test "reports page renders Autarkie & Eigenverbrauchsquote section" do
    DailyTotal.create!(plug_id: "bkw", date: "2026-04-10", energy_wh: 2000)
    DailyEnergySummary.create!(date: "2026-04-10", produced_wh: 2000.0, consumed_wh: 1000.0, self_consumed_wh: 500.0)

    get "/reports"

    assert_response :success
    assert_select ".section-label", text: "Autarkie & Eigenverbrauchsquote"
    assert_select "[data-energy-report-target='ratiosCanvas']", 1
  end
end
