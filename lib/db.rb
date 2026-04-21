require "sequel"

module DB
  def self.connect(path)
    db = Sequel.sqlite(path)
    db.run "PRAGMA journal_mode = WAL;"         unless path == ":memory:"
    db.run "PRAGMA foreign_keys = ON;"
    db
  end

  def self.migrate!(db)
    unless db.table_exists?(:samples)
      db.create_table(:samples) do
        String  :plug_id,     null: false
        Integer :ts,          null: false
        Float   :apower_w,    null: false
        Float   :aenergy_wh,  null: false
        primary_key [:plug_id, :ts]
      end
      db.add_index :samples, :ts, name: :idx_samples_ts
    end

    unless db.table_exists?(:samples_5min)
      db.create_table(:samples_5min) do
        String  :plug_id,          null: false
        Integer :bucket_ts,        null: false
        Float   :avg_power_w,      null: false
        Float   :energy_delta_wh,  null: false
        Integer :sample_count,     null: false
        primary_key [:plug_id, :bucket_ts]
      end
    end

    unless db.table_exists?(:daily_totals)
      db.create_table(:daily_totals) do
        String  :plug_id,    null: false
        String  :date,       null: false
        Float   :energy_wh,  null: false
        primary_key [:plug_id, :date]
      end
    end
  end
end
