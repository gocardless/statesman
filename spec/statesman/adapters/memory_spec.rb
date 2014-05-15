require "spec_helper"
require "statesman/adapters/shared_examples"
require "statesman/adapters/memory_transition"

describe Statesman::Adapters::Memory do
  let(:model) { Class.new { attr_accessor :current_state }.new }

  let(:observer) do
    result = double(Statesman::Machine)
    result.stub(:execute)
    result
  end

  it_behaves_like "an adapter", described_class, Statesman::Adapters::MemoryTransition
  let(:adapter) { described_class.new(Statesman::Adapters::MemoryTransition, model, observer) }

  describe "#revert" do
    let(:from) { :x }
    let(:to) { :y }
    let(:revert) { adapter.revert }
    subject { -> { revert } }

    before do
      adapter.create(:x, :y)
    end

    it { should change(adapter.history, :count).by(-1) }

  end
end
