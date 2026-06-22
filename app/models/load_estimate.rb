# The household-load inputs the controller needs, in one place. current_w is the
# live measured sum (nil when no fresh sample); floor_w is the export-safe 24h
# minimum; median_w caps short live-load spikes; night_base_w is the expected
# overnight base load.
LoadEstimate = Struct.new(:current_w, :floor_w, :median_w, :night_base_w, keyword_init: true) do
  def effective_w
    return floor_w.to_f if current_w.nil?
    return current_w.to_f if median_w.nil?

    [ median_w, current_w ].min.to_f
  end
end
