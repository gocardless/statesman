require "spec_helper"
require "statesman/adapters/adapter_behaviour"
require "statesman/adapters/sql_adapter_behaviour"

describe Statesman::Adapters::Sequel, sequel: true do
  before do
    MySequelModel.dataset = MySequelModel.dataset
    MySequelModelTransition.dataset = MySequelModelTransition.dataset
  end

  let(:observer) { double(Statesman::Machine, execute: nil) }
  let(:model) { MySequelModel.create(current_state: :pending) }

  it_behaves_like "an adapter", described_class, MySequelModelTransition
  it_behaves_like "a SQL adapter", described_class, MySequelModelTransition do
    let(:association_name) { :my_sequel_model_transitions_dataset }
  end
end
