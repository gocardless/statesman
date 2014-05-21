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
end
