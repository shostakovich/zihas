class DashboardChannel < ApplicationCable::Channel
  def subscribed
    stream_from "dashboard"
  end
end
