# Mobile Bottom Navigation Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Add a mobile-only fixed bottom navigation to ZiWoAS using the approved Solar Liquid Glass design and plush icon assets.

**Architecture:** Reuse the existing layout navigation in `app/views/layouts/application.html.erb` and enhance each link with a decorative image plus visible label. Keep the current desktop pill navigation, then use a mobile media query in `app/assets/stylesheets/application.css` to transform the same navigation into a fixed bottom tabbar with safe-area padding.

**Tech Stack:** Rails 8.1, ERB, Propshaft asset pipeline, vanilla CSS, Minitest integration tests.

**Design Source:** `docs/superpowers/specs/2026-06-17-mobile-bottom-navigation-design.md`

**Important repo rule:** Do not commit unless the user explicitly asks. Each task includes a `git status` checkpoint instead of `git commit`.

---

### Task 1: Tighten the existing layout navigation test

**Objective:** Update the current integration test so it expects the new icon+label link structure before implementation.

**Files:**
- Modify: `test/controllers/reports_controller_test.rb:76-87`

**Step 1: Write failing test**

Replace the existing `test "layout includes dashboard and reports navigation"` block in `test/controllers/reports_controller_test.rb` with:

```ruby
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
      assert_select "nav.app-nav a[href='#{path}']" do
        assert_select ".app-nav-label", text: label, count: 1
        assert_select "img.app-nav-icon[alt=''][aria-hidden='true'][src*='#{icon}']", count: 1
      end
    end
  end
```

**Step 2: Run test to verify failure**

Run:

```bash
eval "$(rbenv init -)" && bin/rails test test/controllers/reports_controller_test.rb -n "/layout includes accessible navigation labels/"
```

Expected: FAIL because `.app-nav-label` and `.app-nav-icon` do not exist yet.

**Step 3: Check worktree**

Run:

```bash
git status --short -- test/controllers/reports_controller_test.rb
```

Expected: `M test/controllers/reports_controller_test.rb`.

---

### Task 2: Render navigation links with plush icons and labels

**Objective:** Change the shared layout navigation markup to include the decorative icon image and visible label for each route.

**Files:**
- Modify: `app/views/layouts/application.html.erb:32-38`
- Test: `test/controllers/reports_controller_test.rb`

**Step 1: Confirm failing test still fails**

Run:

```bash
eval "$(rbenv init -)" && bin/rails test test/controllers/reports_controller_test.rb -n "/layout includes accessible navigation labels/"
```

Expected: FAIL for missing `.app-nav-label`/`.app-nav-icon`.

**Step 2: Implement minimal ERB markup**

Replace the `<nav class="app-nav" ...>` block in `app/views/layouts/application.html.erb` with:

```erb
      <nav class="app-nav" aria-label="Hauptnavigation">
        <%= link_to root_path, class: [ "app-nav-link", ("active" if current_page?(root_path)) ] do %>
          <%= image_tag "nav_dashboard_plush.webp", alt: "", class: "app-nav-icon", aria: { hidden: true } %>
          <span class="app-nav-label">Home</span>
        <% end %>
        <%= link_to switches_path, class: [ "app-nav-link", ("active" if current_page?(switches_path)) ] do %>
          <%= image_tag "nav_switches_plush.webp", alt: "", class: "app-nav-icon", aria: { hidden: true } %>
          <span class="app-nav-label">Schalten</span>
        <% end %>
        <%= link_to reports_path, class: [ "app-nav-link", ("active" if current_page?(reports_path)) ] do %>
          <%= image_tag "nav_reports_plush.webp", alt: "", class: "app-nav-icon", aria: { hidden: true } %>
          <span class="app-nav-label">Berichte</span>
        <% end %>
        <%= link_to weather_path, class: [ "app-nav-link", ("active" if current_page?(weather_path)) ] do %>
          <%= image_tag "nav_weather_plush.webp", alt: "", class: "app-nav-icon", aria: { hidden: true } %>
          <span class="app-nav-label">Wetter</span>
        <% end %>
        <%= link_to sensors_path, class: [ "app-nav-link", ("active" if current_page?(sensors_path)) ] do %>
          <%= image_tag "nav_sensors_plush.webp", alt: "", class: "app-nav-icon", aria: { hidden: true } %>
          <span class="app-nav-label">Sensoren</span>
        <% end %>
      </nav>
```

**Step 3: Run test to verify pass**

Run:

```bash
eval "$(rbenv init -)" && bin/rails test test/controllers/reports_controller_test.rb -n "/layout includes accessible navigation labels/"
```

Expected: PASS. If SimpleCov exits non-zero due to coverage threshold, treat the test as passed only if the output shows `0 failures, 0 errors` above the SimpleCov message.

**Step 4: Check worktree**

Run:

```bash
git status --short -- app/views/layouts/application.html.erb test/controllers/reports_controller_test.rb app/assets/images/nav_*_plush.webp
```

Expected: modified layout/test plus the five untracked `nav_*_plush.webp` assets.

---

### Task 3: Add desktop-safe base styles for icon/label navigation

**Objective:** Hide plush icons on desktop and preserve the current desktop pill navigation appearance.

**Files:**
- Modify: `app/assets/stylesheets/application.css:163-193`
- Test: `test/controllers/reports_controller_test.rb`

**Step 1: Write failing CSS presence test**

Add these assertions at the end of the navigation test from Task 1:

```ruby
    stylesheet = Rails.root.join("app/assets/stylesheets/application.css").read
    assert_includes stylesheet, ".app-nav-icon"
    assert_includes stylesheet, "display: none;"
    assert_includes stylesheet, ".app-nav-label"
```

**Step 2: Run test to verify failure**

Run:

```bash
eval "$(rbenv init -)" && bin/rails test test/controllers/reports_controller_test.rb -n "/layout includes accessible navigation labels/"
```

Expected: FAIL because `.app-nav-icon` has not been defined in CSS.

**Step 3: Add base CSS**

Insert this block after the existing `.app-nav-link.active` rule in `app/assets/stylesheets/application.css`:

```css
.app-nav-icon {
  display: none;
}

.app-nav-label {
  display: inline;
}
```

**Step 4: Run test to verify pass**

Run:

```bash
eval "$(rbenv init -)" && bin/rails test test/controllers/reports_controller_test.rb -n "/layout includes accessible navigation labels/"
```

Expected: PASS. Ignore SimpleCov coverage exit only if the test summary has `0 failures, 0 errors`.

**Step 5: Check worktree**

Run:

```bash
git status --short -- app/assets/stylesheets/application.css test/controllers/reports_controller_test.rb
```

Expected: both files modified.

---

### Task 4: Add mobile bottom-navigation CSS

**Objective:** Add the mobile media query that turns `.app-nav` into the approved fixed Solar Liquid Glass bottom navigation.

**Files:**
- Modify: `app/assets/stylesheets/application.css`
- Test: `test/controllers/reports_controller_test.rb`

**Step 1: Write failing CSS contract assertions**

Add these assertions to the same navigation test, after the Task 3 CSS assertions:

```ruby
    assert_includes stylesheet, "@media (max-width: 640px)"
    assert_includes stylesheet, "bottom: calc(14px + env(safe-area-inset-bottom));"
    assert_includes stylesheet, "backdrop-filter: blur(28px) saturate(1.65);"
    assert_includes stylesheet, "grid-template-columns: repeat(5, minmax(0, 1fr));"
    assert_includes stylesheet, "width: 32px;"
    assert_includes stylesheet, "font-weight: 500;"
```

**Step 2: Run test to verify failure**

Run:

```bash
eval "$(rbenv init -)" && bin/rails test test/controllers/reports_controller_test.rb -n "/layout includes accessible navigation labels/"
```

Expected: FAIL because the mobile media query does not exist yet.

**Step 3: Add mobile CSS**

Append this block near the existing navigation styles, after the base `.app-nav-label` block:

```css
@media (max-width: 640px) {
  body {
    padding-bottom: calc(104px + env(safe-area-inset-bottom));
  }

  .app-header {
    justify-content: center;
    border-bottom: none;
    padding-bottom: 0;
  }

  .app-header .app-nav {
    position: fixed;
    left: 16px;
    right: 16px;
    bottom: calc(14px + env(safe-area-inset-bottom));
    z-index: 90;
    display: grid;
    grid-template-columns: repeat(5, minmax(0, 1fr));
    gap: 5px;
    min-height: 74px;
    padding: 7px;
    border-radius: 25px;
    background: linear-gradient(145deg, rgba(255, 255, 255, 0.36), rgba(255, 248, 219, 0.46));
    border: 1px solid rgba(255, 255, 255, 0.72);
    box-shadow:
      0 18px 44px rgba(15, 23, 42, 0.18),
      inset 0 1px 0 rgba(255, 255, 255, 0.9),
      inset 0 -1px 0 rgba(245, 159, 0, 0.16);
    backdrop-filter: blur(28px) saturate(1.65);
    -webkit-backdrop-filter: blur(28px) saturate(1.65);
  }

  .app-header .app-nav-link {
    min-width: 0;
    min-height: 60px;
    border-radius: 17px;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 2px;
    padding: 4px 3px;
    color: #6f5600;
    font-size: 9px;
    font-weight: 500;
    line-height: 1.1;
    letter-spacing: 0;
    text-align: center;
  }

  .app-header .app-nav-link.active {
    color: var(--text);
    background: linear-gradient(135deg, rgba(255, 224, 102, 0.78), rgba(255, 255, 255, 0.36));
    box-shadow:
      inset 0 1px 0 rgba(255, 255, 255, 0.88),
      0 8px 18px rgba(245, 159, 0, 0.13);
  }

  .app-nav-icon {
    display: block;
    width: 32px;
    height: 32px;
    object-fit: contain;
    filter: drop-shadow(0 3px 4px rgba(124, 94, 0, 0.13));
  }

  .app-nav-label {
    display: block;
    max-width: 100%;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
}
```

**Step 4: Run test to verify pass**

Run:

```bash
eval "$(rbenv init -)" && bin/rails test test/controllers/reports_controller_test.rb -n "/layout includes accessible navigation labels/"
```

Expected: PASS. Ignore SimpleCov coverage exit only if the test summary has `0 failures, 0 errors`.

**Step 5: Check worktree**

Run:

```bash
git status --short -- app/assets/stylesheets/application.css test/controllers/reports_controller_test.rb
```

Expected: both files modified.

---

### Task 5: Add a mobile system test for fixed bottom navigation

**Objective:** Verify in a real browser that the mobile navigation is fixed near the bottom and has the expected five labels.

**Files:**
- Create: `test/system/mobile_navigation_test.rb`

**Step 1: Write failing system test**

Create `test/system/mobile_navigation_test.rb` with:

```ruby
require "application_system_test_case"

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
      const nav = document.querySelector('nav.app-nav');
      const rect = nav.getBoundingClientRect();
      const styles = window.getComputedStyle(nav);
      ({ position: styles.position, bottom: window.innerHeight - rect.bottom, columns: styles.gridTemplateColumns.split(' ').length });
    JS

    assert_equal "fixed", nav_box.fetch("position")
    assert_operator nav_box.fetch("bottom"), :<, 40
    assert_equal 5, nav_box.fetch("columns")
  end
end
```

**Step 2: Run test to verify failure or pass depending on Task 4 state**

Run:

```bash
eval "$(rbenv init -)" && bin/rails test test/system/mobile_navigation_test.rb
```

Expected after Task 4: PASS. If run before Task 4, expected failure on `position` not being `fixed`.

**Step 3: Check worktree**

Run:

```bash
git status --short -- test/system/mobile_navigation_test.rb
```

Expected: `?? test/system/mobile_navigation_test.rb`.

---

### Task 6: Run focused verification

**Objective:** Verify the layout integration and mobile browser behavior together.

**Files:**
- Test only; no code changes expected.

**Step 1: Run focused integration test**

Run:

```bash
eval "$(rbenv init -)" && bin/rails test test/controllers/reports_controller_test.rb -n "/layout includes accessible navigation labels/"
```

Expected: PASS or `0 failures, 0 errors` above any SimpleCov coverage warning.

**Step 2: Run mobile system test**

Run:

```bash
eval "$(rbenv init -)" && bin/rails test test/system/mobile_navigation_test.rb
```

Expected: PASS or `0 failures, 0 errors` above any SimpleCov coverage warning.

**Step 3: Run all controller tests affected by layout**

Run:

```bash
eval "$(rbenv init -)" && bin/rails test test/controllers
```

Expected: PASS or `0 failures, 0 errors` above any SimpleCov coverage warning.

**Step 4: Check worktree**

Run:

```bash
git status --short
```

Expected: only intended files are changed/added:

```text
M  app/assets/stylesheets/application.css
M  app/views/layouts/application.html.erb
M  test/controllers/reports_controller_test.rb
?? app/assets/images/nav_dashboard_plush.webp
?? app/assets/images/nav_reports_plush.webp
?? app/assets/images/nav_sensors_plush.webp
?? app/assets/images/nav_switches_plush.webp
?? app/assets/images/nav_weather_plush.webp
?? docs/superpowers/plans/2026-06-17-mobile-bottom-navigation.md
?? docs/superpowers/specs/2026-06-17-mobile-bottom-navigation-design.md
?? test/system/mobile_navigation_test.rb
```

There may already be unrelated pre-existing worktree changes in this repo. Do not modify or revert unrelated files.

---

### Task 7: Manual visual verification in local browser

**Objective:** Confirm the implemented UI matches the approved mockup on desktop and mobile.

**Files:**
- No file edits expected.

**Step 1: Start Rails server if needed**

Run:

```bash
eval "$(rbenv init -)" && bin/rails server -p 3000
```

Expected: Rails server starts successfully. If port 3000 is busy, use another port, e.g. `PORT=3001 bin/dev` or `bin/rails server -p 3001`.

**Step 2: Verify desktop**

Open the app at `http://localhost:3000` with a desktop viewport.

Expected:
- Header logo remains visible.
- Desktop nav still appears as the existing top pill navigation.
- Plush icons are hidden on desktop.

**Step 3: Verify mobile viewport**

Use browser device emulation around `390 × 844`.

Expected:
- Header logo remains visible at top.
- Navigation appears as fixed bottom Frosted Tray / Solar Liquid Glass bar.
- Five smaller plush icons are visible.
- Labels are not bold.
- Scrolling does not move the bottom navigation.
- Page content is not hidden behind the bottom navigation.

**Step 4: Stop server**

Stop the Rails server with `Ctrl+C` if it was started in the foreground, or kill the tracked background process if started through Hermes.

---

### Task 8: Final cleanup and handoff

**Objective:** Prepare the feature for user review without committing.

**Files:**
- No new edits unless verification found issues.

**Step 1: Run final status**

Run:

```bash
git status --short
```

Expected: only intended files plus pre-existing unrelated changes.

**Step 2: Summarize changed files**

Run:

```bash
git diff -- app/views/layouts/application.html.erb app/assets/stylesheets/application.css test/controllers/reports_controller_test.rb test/system/mobile_navigation_test.rb docs/superpowers/specs/2026-06-17-mobile-bottom-navigation-design.md docs/superpowers/plans/2026-06-17-mobile-bottom-navigation.md
```

Expected: diff shows only mobile navigation implementation, tests, spec, and plan.

**Step 3: Ask before commit**

Do not commit automatically. Ask the user whether to commit the feature once they have reviewed it.
