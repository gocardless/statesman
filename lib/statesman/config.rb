# frozen_string_literal: true

require "json"
require_relative "exceptions"

module Statesman
  class Config
    attr_reader :adapter_class

    def initialize(block = nil)
      instance_eval(&block) unless block.nil?
    end

    def storage_adapter(adapter_class)
      @adapter_class = adapter_class
    end

    def mysql_gaplock_protection?(connection)
      # If our adapter class suggests we're using mysql, enable gaplock protection by
      # default.
      mysql_adapter?(connection)
    end

    private

    def mysql_adapter?(adapter_class)
      adapter_name = adapter_name(adapter_class)
      return false unless adapter_name

      adapter_name.downcase.start_with?("mysql")
    end

    def adapter_name(adapter_class)
      adapter_class.respond_to?(:adapter_name) && adapter_class&.adapter_name
    end
  end
end
