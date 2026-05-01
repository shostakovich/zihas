require 'sqlite3'

source_db = SQLite3::Database.new("data/ziwoas.db")
dest_db = SQLite3::Database.new("storage/development.sqlite3")

%w[samples daily_totals].each do |table|
  puts "Copying #{table}..."
  rows = source_db.execute("SELECT * FROM #{table}")
  dest_db.transaction do
    rows.each do |row|
      placeholders = Array.new(row.length, "?").join(", ")
      dest_db.execute("INSERT OR IGNORE INTO #{table} VALUES (#{placeholders})", row)
    end
  end
end

puts "Done!"
