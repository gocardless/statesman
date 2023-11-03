# frozen_string_literal: true

require "spec_helper"
require "json"

describe Statesman::Adapters::ActiveRecordTransition do
  let(:transition_class) { Class.new { def self.serialize(*_args); end } }

  describe "including behaviour" do
    it "calls Class.serialize" do
      if Gem::Version.new(ActiveRecord::VERSION::STRING) >= Gem::Version.new("7.1")
        expect(transition_class).to receive(:serialize).with(:metadata, coder: JSON).once
      else
        expect(transition_class).to receive(:serialize).with(:metadata, JSON).once
      end
      transition_class.send(:include, described_class)
    end
  end
end
