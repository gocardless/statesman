require "spec_helper"
require "statesman/adapters/shared_examples"

describe Statesman::Adapters::ActiveRecord do
  before do
    prepare_model_table
    prepare_transitions_table
  end

  let(:model) { MyModel.create(current_state: :pending) }
  it_behaves_like "an adapter", described_class, MyModelTransition
end
