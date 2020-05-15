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

    def mysql_gaplock_protection?
      return @mysql_gaplock_protection unless @mysql_gaplock_protection.nil?

      # If our adapter class suggests we're using mysql, enable gaplock protection by
      # default.
      enable_mysql_gaplock_protection if mysql_adapter?(adapter_class)
      @mysql_gaplock_protection
    end

    def enable_mysql_gaplock_protection
      @mysql_gaplock_protection = true
    end

    private

    def mysql_adapter?(adapter_class)
      adapter_name = adapter_name(adapter_class)
      return false unless adapter_name

      adapter_name.start_with?("mysql")
    end

    def adapter_name(adapter_class)
      adapter_class.respond_to?(:adapter_name) && adapter_class&.adapter_name
    end
  end
end
