# frozen_string_literal: true

require "json"
require_relative "exceptions"

module Statesman
  class Config
    attr_reader :adapter_class, :gaplock_protection_enabled

    def initialize(block = nil)
      @gaplock_protection_enabled = false
      instance_eval(&block) unless block.nil?
    end

    def storage_adapter(adapter_class)
      @adapter_class = adapter_class
    end

    def mysql_gaplock_protection(gaplock_protection)
      @gaplock_protection_enabled = gaplock_protection
    end
  end
end
