class SolakonControlState < ApplicationRecord
  def self.current
    first_or_create!
  end

  def auto_regulation_active?
    !auto_regulation_paused?
  end

  def pause_auto_regulation!
    update!(auto_regulation_paused: true)
  end

  def resume_auto_regulation!
    update!(auto_regulation_paused: false)
  end
end
