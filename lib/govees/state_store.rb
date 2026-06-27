# lib/govees/state_store.rb
module Govees
  # Per-lamp desired/confirmed state + conflict resolution. Pure logic, no I/O.
  #
  # Rules:
  #  - record_command: set desired optimistically, status PENDING for a window.
  #  - During PENDING, a LAN reading that matches desired confirms (SYNCED);
  #    one that deviates is treated as "not yet applied" and ignored.
  #  - After the window (or when not pending): off is adopted immediately;
  #    on+deviation from a :lan source flags needs_api_clarification (RECONCILING);
  #    :api telemetry is always adopted as the authoritative truth.
  class StateStore
    # Fields compared to decide "deviation" (zone_states/reachable excluded).
    COMPARE = %i[on brightness color color_temp_k].freeze

    Entry = Struct.new(:published, :status, :pending_until, keyword_init: true)

    def initialize(pending_window_s: 5.0, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @window = pending_window_s
      @clock  = clock
      @entries = {}
    end

    def published(key) = @entries[key]&.published&.dup
    def status(key)    = @entries[key]&.status

    def record_command(key, changes)
      entry = (@entries[key] ||= Entry.new(published: {}, status: :synced, pending_until: 0.0))
      entry.published = entry.published.merge(normalize(changes))
      entry.status = :pending
      entry.pending_until = @clock.call + @window
      entry.published.dup
    end

    def apply_telemetry(key, telemetry, source:)
      tel = normalize(telemetry)
      entry = (@entries[key] ||= Entry.new(published: {}, status: :synced, pending_until: 0.0))

      if entry.status == :pending && @clock.call < entry.pending_until
        if matches?(entry.published, tel)
          entry.published = entry.published.merge(tel)
          entry.status = :synced
        end # else: not applied yet -> hold optimistic, ignore
        return result(entry, false)
      end

      if tel[:on] == false
        entry.published = entry.published.merge(tel)
        entry.status = :synced
        return result(entry, false)
      end

      if source == :lan && !matches?(entry.published, tel)
        entry.status = :reconciling
        return result(entry, true)
      end

      entry.published = entry.published.merge(tel)
      entry.status = :synced
      result(entry, false)
    end

    private

    def result(entry, needs_api) = { published: entry.published.dup, changed: true, needs_api_clarification: needs_api }

    # Only the fields present in telemetry are compared; a field absent from the
    # reading never counts as a deviation.
    def matches?(published, tel)
      COMPARE.all? { |f| !tel.key?(f) || published[f] == tel[f] }
    end

    def normalize(h) = h.transform_keys(&:to_sym)
  end
end
