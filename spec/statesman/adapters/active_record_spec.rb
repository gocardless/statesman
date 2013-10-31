require "spec_helper"
require "statesman/adapters/shared_examples"
require "statesman/exceptions"

describe Statesman::Adapters::ActiveRecord do
  before do
    prepare_model_table
    prepare_transitions_table
  end

  before { MyActiveRecordModelTransition.serialize(:metadata, JSON) }

  let(:model) { MyActiveRecordModel.create(current_state: :pending) }
  it_behaves_like "an adapter", described_class, MyActiveRecordModelTransition

  describe "#initialize" do
    context "with unserialized metadata" do
      before { MyActiveRecordModelTransition.stub(serialized_attributes: {}) }

      it "raises an exception if metadata is not serialized" do
        expect do
          described_class.new(MyActiveRecordModelTransition,
                              MyActiveRecordModel)
        end.to raise_exception(Statesman::UnserializedMetadataError)
      end
    end
  end

  describe "#last" do
    let(:adapter) { described_class.new(MyActiveRecordModelTransition, model) }

    context "with a previously looked up transition" do
      before do
        adapter.create(:y, [], [])
        adapter.last
      end

      it "caches the transition" do
        MyActiveRecordModel.any_instance
          .should_receive(:my_active_record_model_transitions).never
        adapter.last
      end

      context "and a new transition" do
        before { adapter.create(:z, [], []) }
        it "retrieves the new transition from the database" do
          expect(adapter.last.to_state).to eq("z")
        end
      end
    end
  end
end
