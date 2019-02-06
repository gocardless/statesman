require "spec_helper"

describe Statesman::Config do
  let(:instance) { described_class.new }

  after do
    Statesman.configure do
      storage_adapter(Statesman::Adapters::Memory)
      requires_new_transaction(true)
    end
  end

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

  describe "#requires_new_transaction" do
    subject { instance.requires_new }

    let(:choice) { false }

    before { instance.requires_new_transaction(choice) }

    it { is_expected.to be(choice) }

    it "is DSL configurable" do
      new_choice = choice
      Statesman.configure { requires_new_transaction(new_choice) }

      defined_choice = nil
      Statesman.instance_eval { defined_choice = @requires_new }
      expect(defined_choice).to be(new_choice)
    end
  end
end
