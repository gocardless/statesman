require "spec_helper"

describe Statesman::Config do
  let(:instance) { Statesman::Config.new }

  after do
    # Don't leak global config changes into other specs
    Statesman.configure { storage_adapter(Statesman::Adapters::Memory) }
  end

  describe "#storage_adapter" do
    let(:adapter) { Class.new }
    before  { instance.storage_adapter(adapter) }
    subject { instance.adapter_class }
    it { should be(adapter) }

    it "is DSL configurable" do
      new_adapter = adapter
      Statesman.configure { storage_adapter(new_adapter) }

      defined_adapter = nil
      Statesman.instance_eval { defined_adapter = @storage_adapter }
      expect(defined_adapter).to be(new_adapter)
    end
  end

  describe "#transition_class" do
    it "serializes metadata to JSON" do
      klass = Class.new
      klass.should_receive(:serialize).once.with(:metadata, JSON)
      Statesman.configure { transition_class(klass) }
    end
  end
end
