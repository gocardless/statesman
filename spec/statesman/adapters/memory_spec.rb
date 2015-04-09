require "spec_helper"
require "statesman/adapters/adapter_behaviour"
require "statesman/adapters/memory_transition"

describe Statesman::Adapters::Memory do
  let(:model) { Class.new { attr_accessor :current_state }.new }
  it_behaves_like "an adapter", described_class,
                  Statesman::Adapters::MemoryTransition
end
