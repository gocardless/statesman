require "spec_helper"
require "statesman/adapters/shared_examples"
require "statesman/exceptions"

describe Statesman::Adapters::ActiveRecord do
  before do
    prepare_model_table
    prepare_transitions_table
  end

  before { MyActiveRecordModelTransition.serialize(:metadata, JSON) }
  let(:observer) do
    result = double(Statesman::Machine)
    result.stub(:execute)
    result
  end
  let(:model) { MyActiveRecordModel.create(current_state: :pending) }
  it_behaves_like "an adapter", described_class, MyActiveRecordModelTransition

  describe "#initialize" do
    context "with unserialized metadata" do
      before { MyActiveRecordModelTransition.stub(serialized_attributes: {}) }

      it "raises an exception if metadata is not serialized" do
        expect do
          described_class.new(MyActiveRecordModelTransition,
                              MyActiveRecordModel, observer)
        end.to raise_exception(Statesman::UnserializedMetadataError)
      end
    end
  end

  describe "#last" do
    let(:adapter) do
      described_class.new(MyActiveRecordModelTransition, model, observer)
    end

    before do
      adapter.create(:x, :y)
    end

    context "with a previously looked up transition" do
      before do
        adapter.last
      end

      it "caches the transition" do
        MyActiveRecordModel.any_instance
          .should_receive(:my_active_record_model_transitions).never
        adapter.last
      end

      context "and a new transition" do
        before { adapter.create(:y, :z, []) }
        it "retrieves the new transition from the database" do
          expect(adapter.last.to_state).to eq("z")
        end
      end

      context "with a pre-fetched transition history" do
        before do
            # inspect the transitions to coerce a [pre-]load
          model.my_active_record_model_transitions.inspect
        end

        it "doesn't query the database" do
          MyActiveRecordModelTransition.should_not_receive(:connection)
          expect(adapter.last.to_state).to eq("y")
        end
      end
    end

    describe "#revert" do

      let(:adapter) do
        described_class.new(MyActiveRecordModelTransition, model, observer)
      end
      let(:revert) { adapter.revert }
      subject { -> { revert } }

      before do
        adapter.create(:x, :y)
      end
      it { should change(adapter.history, :count).by(-1) }

    end
  end
end
