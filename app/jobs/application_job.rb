class ApplicationJob < ActiveJob::Base
  retry_on ActiveRecord::Deadlocked, wait: :polynomially_longer, attempts: 3
  retry_on SQLite3::BusyException, wait: :polynomially_longer, attempts: 3
  discard_on ActiveJob::DeserializationError
end
