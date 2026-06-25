class SceneEntry < ApplicationRecord
  belongs_to :scene
  belongs_to :light
  belongs_to :preset
end
