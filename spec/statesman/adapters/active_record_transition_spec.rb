require "spec_helper"
require "json"

describe Statesman::Adapters::ActiveRecordTransition do
  let(:transition_class) { Class.new { def self.serialize(*_args); end } }

  describe "including behaviour" do
    it "calls Class.serialize" do
      expect(transition_class).to receive(:serialize).with(:metadata, JSON).once
      transition_class.send(:include, described_class)
    end
  end
end
