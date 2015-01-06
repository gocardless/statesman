require "spec_helper"
require "statesman/adapters/shared_examples"
require "statesman/exceptions"
require "support/mongoid"
require "mongoid"

describe Statesman::Adapters::Mongoid, mongo: true do
  after do
    Mongoid.purge!
  end
  let(:observer) do
    result = double(Statesman::Machine)
    allow(result).to receive(:execute)
    result
  end
  let(:model) { MyMongoidModel.create(current_state: :pending) }
  it_behaves_like "an adapter", described_class, MyMongoidModelTransition

  describe "#initialize" do
    context "with unserialized metadata" do
      before do
        allow_any_instance_of(described_class)
          .to receive_messages(transition_class_hash_fields: [])
      end

      it "raises an exception if metadata is not serialized" do
        expect do
          described_class.new(MyMongoidModelTransition, MyMongoidModel,
                              observer)
        end.to raise_exception(Statesman::UnserializedMetadataError)
      end
    end
  end

  describe "#last" do
    let(:adapter) do
      described_class.new(MyMongoidModelTransition, model, observer)
    end

    context "with a previously looked up transition" do
      before do
        adapter.create(:x, :y)
        adapter.last
      end

      it "caches the transition" do
        expect_any_instance_of(MyMongoidModel)
          .to receive(:my_mongoid_model_transitions).never
        adapter.last
      end

      context "and a new transition" do
        before { adapter.create(:y, :z) }
        it "retrieves the new transition from the database" do
          expect(adapter.last.to_state).to eq("z")
        end
      end
    end
  end
end
