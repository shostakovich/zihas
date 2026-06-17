require_relative "application_system_test_case"

class MobileNavigationTest < ApplicationSystemTestCase
  test "mobile navigation is fixed at the bottom with all primary links" do
    page.driver.browser.manage.window.resize_to(390, 844)

    visit root_path

    within "nav.app-nav" do
      assert_text "Home"
      assert_text "Schalten"
      assert_text "Berichte"
      assert_text "Wetter"
      assert_text "Sensoren"
    end

    nav_box = page.evaluate_script(<<~JS)
      (() => {
      const nav = document.querySelector('nav.app-nav');
      const rect = nav.getBoundingClientRect();
      const styles = window.getComputedStyle(nav);
      return { position: styles.position, bottom: window.innerHeight - rect.bottom, columns: styles.gridTemplateColumns.split(' ').length };
      })();
    JS

    assert_equal "fixed", nav_box.fetch("position")
    assert_operator nav_box.fetch("bottom"), :<, 40
    assert_equal 5, nav_box.fetch("columns")
  end
end
