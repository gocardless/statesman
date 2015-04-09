require "spec_helper"
require "statesman/adapters/shared_examples"

describe Statesman::Adapters::Sequel, sequel: true do
  before do
    MySequelModel.dataset = MySequelModel.dataset
    MySequelModelTransition.dataset = MySequelModelTransition.dataset
  end

  let(:observer) { double(Statesman::Machine, execute: nil) }
  let(:model) { MySequelModel.create(current_state: :pending) }

  it_behaves_like "an adapter", described_class, MySequelModelTransition
end
