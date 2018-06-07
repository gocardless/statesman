require "spec_helper"

describe Statesman::Config do
  let(:instance) { described_class.new }

  after { Statesman.configure { storage_adapter(Statesman::Adapters::Memory) } }

  describe "#storage_adapter" do
    subject { instance.adapter_class }

    let(:adapter) { Class.new }

    before { instance.storage_adapter(adapter) }

    it { is_expected.to be(adapter) }

    it "is DSL configurable" do
      new_adapter = adapter
      Statesman.configure { storage_adapter(new_adapter) }

      defined_adapter = nil
      Statesman.instance_eval { defined_adapter = @storage_adapter }
      expect(defined_adapter).to be(new_adapter)
    end
  end
end
