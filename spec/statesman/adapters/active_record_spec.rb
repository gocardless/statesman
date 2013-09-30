require "spec_helper"
require "statesman/adapters/shared_examples"
require "statesman/exceptions"

describe Statesman::Adapters::ActiveRecord do
  before do
    prepare_model_table
    prepare_transitions_table
  end

  before { MyModelTransition.serialize(:metadata, JSON) }

  let(:model) { MyModel.create(current_state: :pending) }
  it_behaves_like "an adapter", described_class, MyModelTransition

  describe "#initialize" do
    context "with unserialized metadata" do
      before { MyModelTransition.stub(serialized_attributes: {}) }

      it "raises an exception if metadata is not serialized" do
        expect do
          described_class.new(MyModelTransition, MyModel)
        end.to raise_exception(Statesman::UnserializedMetadataError)
      end

    end
  end
end
