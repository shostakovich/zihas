# lib/govees/device.rb
require "dry/struct"
require "govees/types"

module Govees
  # Immutable canonical lamp record. `ip` is updated by DeviceRegistry via
  # copy-on-write (device.new(ip:)) since Dry::Struct is frozen.
  class Device < Dry::Struct
    attribute :key,                 Types::String
    attribute :api_id,              Types::String
    attribute :sku,                 Types::String
    attribute :name,                Types::String
    attribute :ip,                  Types::String.optional
    attribute :supports_color,      Types::Bool
    attribute :supports_color_temp, Types::Bool
    attribute :zones,               Types::Array.of(Types::String)
    attribute :scenes,              Types::Array.of(Types::String)
    attribute :scene_index,         Types::Hash
    attribute :power_only,          Types::Bool
  end
end
