module Lights
  class ToastComponent < ApplicationComponent
    def initialize(message:, undo:)
      @message = message
      @undo = undo
    end

    private

    attr_reader :message, :undo
  end
end
