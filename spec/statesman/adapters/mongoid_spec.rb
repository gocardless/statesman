require "spec_helper"
require "statesman/adapters/shared_examples"
require "statesman/exceptions"
require "support/mongoid"
require "mongoid"

describe Statesman::Adapters::Mongoid do

  after do
    Mongoid.purge!
  end

  let(:model) { MyMongoidModel.create(current_state: :pending) }
  it_behaves_like "an adapter", described_class, MyMongoidModelTransition

  describe "#initialize" do
    context "with unserialized metadata" do
      before do
        described_class.any_instance.stub(transition_class_hash_fields: [])
      end

      it "raises an exception if metadata is not serialized" do
        expect do
          described_class.new(MyMongoidModelTransition, MyMongoidModel)
        end.to raise_exception(Statesman::UnserializedMetadataError)
      end
    end
  end

  describe "#last" do
    let(:adapter) { described_class.new(MyMongoidModelTransition, model) }

    context "with a previously looked up transition" do
      before do
        adapter.create(:y, [], [])
        adapter.last
      end

      it "caches the transition" do
        MyMongoidModel.any_instance
          .should_receive(:my_mongoid_model_transitions).never
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
