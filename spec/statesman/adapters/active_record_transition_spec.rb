require "spec_helper"
require "json"

describe Statesman::Adapters::ActiveRecordTransition do
  let(:transition_class) { Class.new }

  describe "including behaviour" do
    it "calls Class.serialize" do
      transition_class.should_receive(:serialize).with(:metadata, JSON).once
      transition_class.send(:include, described_class)
    end
  end
end
