module Statesman
  module Utils
    def self.rails_major_version
      Rails.version.split(".").map(&:to_i).first
    end

    def self.rails_5_or_higher?
      rails_major_version >= 5
    end

    def self.rails_4_or_higher?
      rails_major_version >= 4
    end
  end
end
