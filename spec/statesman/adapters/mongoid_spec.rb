require "spec_helper"
require "statesman/adapters/shared_examples"
require "statesman/exceptions"
require "support/mongoid"
require "mongoid"

describe Statesman::Adapters::Mongoid, mongo: true do
  after { Mongoid.purge! }
  let(:observer) { double(Statesman::Machine, execute: nil) }
  let(:model) { MyMongoidModel.create(current_state: :pending) }
  it_behaves_like "an adapter", described_class, MyMongoidModelTransition

  describe "#initialize" do
    context "with unserialized metadata" do
      before do
        allow_any_instance_of(described_class).
          to receive_messages(transition_class_hash_fields: [])
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
      before { adapter.create(:x, :y) }
      before { adapter.last }

      it "caches the transition" do
        expect_any_instance_of(MyMongoidModel).
          to receive(:my_mongoid_model_transitions).never
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
