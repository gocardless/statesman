# frozen_string_literal: true

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

    it "includes Statesman::Adapters::ActiveRecordTransitionAttributes" do
      transition_class.send(:include, described_class)

      expect(transition_class.ancestors).
        to include(Statesman::Adapters::ActiveRecordTransitionAttributes)
    end

    it "defaults updated_timestamp_column to :updated_at" do
      transition_class.send(:include, described_class)

      expect(transition_class.updated_timestamp_column).to eq(:updated_at)
    end
  end
end
