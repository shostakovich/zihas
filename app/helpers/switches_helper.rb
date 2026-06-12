module SwitchesHelper
  DAY_ABBR = { 1 => "Mo", 2 => "Di", 3 => "Mi", 4 => "Do", 5 => "Fr", 6 => "Sa", 7 => "So" }.freeze
  SOURCE_LABEL = { "manual" => "manuell", "schedule" => "Zeitplan" }.freeze

  def weekday_label(days)
    sorted = days.sort
    return "täglich" if sorted == SwitchWindow::ISO_DAYS
    sorted.slice_when { |a, b| b != a + 1 }
          .map { |group| group.size >= 2 ? "#{DAY_ABBR[group.first]}–#{DAY_ABBR[group.last]}" : DAY_ABBR[group.first] }
          .join(", ")
  end

  def window_label(window)
    "#{weekday_label(window.days)} · #{window.on_at_time}–#{window.off_at_time}"
  end

  def switch_status_line(row)
    return offline_line(row) if row.offline?

    state_word = row.on? ? "an" : "aus"
    cmd        = row.last_command
    first_part =
      if cmd && (cmd.action == "on") == row.on?
        "#{state_word} seit #{cmd.created_at.strftime('%H:%M')} (#{SOURCE_LABEL[cmd.source]})"
      else
        state_word
      end
    [ first_part, schedule_part(row) ].join(" · ")
  end

  private

  def offline_line(row)
    return "noch keine Statusmeldung" if row.last_seen_at.nil?
    minutes = ((row.now - row.last_seen_at) / 60).round
    "keine Statusmeldung seit #{minutes} min"
  end

  def schedule_part(row)
    if row.next_edge
      arrow = row.next_edge.action == :on ? "an" : "aus"
      "nächste Schaltung: #{row.next_edge.at.strftime('%H:%M')} → #{arrow}"
    else
      "kein Zeitplan"
    end
  end
end
