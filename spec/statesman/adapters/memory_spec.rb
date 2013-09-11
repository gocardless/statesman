require "spec_helper"
require "statesman/adapters/shared_examples"

describe Statesman::Adapters::Memory do
  let(:model) { Class.new { attr_accessor :current_state }.new }
  it_behaves_like "an adapter", described_class, Statesman::Transition
end
