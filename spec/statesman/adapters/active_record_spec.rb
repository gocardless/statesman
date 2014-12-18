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
    allow(result).to receive(:execute)
    result
  end
  let(:model) { MyActiveRecordModel.create(current_state: :pending) }
  it_behaves_like "an adapter", described_class, MyActiveRecordModelTransition

  describe "#initialize" do
    context "with unserialized metadata and non json column type" do
      before do
        metadata_column = double
        allow(metadata_column).to receive_messages(sql_type: '')
        allow(MyActiveRecordModelTransition).to receive_messages(columns_hash:
                                           { 'metadata' => metadata_column })
        if ::ActiveRecord.respond_to?(:gem_version) &&
           ::ActiveRecord.gem_version >= Gem::Version.new('4.2.0.a')
          allow(metadata_column).to receive_messages(cast_type: '')
        else
          allow(MyActiveRecordModelTransition)
            .to receive_messages(serialized_attributes: {})
        end
      end

      it "raises an exception" do
        expect do
          described_class.new(MyActiveRecordModelTransition,
                              MyActiveRecordModel, observer)
        end.to raise_exception(Statesman::UnserializedMetadataError)
      end
    end

    context "with serialized metadata and json column type" do
      before do
        metadata_column = double
        allow(metadata_column).to receive_messages(sql_type: 'json')
        allow(MyActiveRecordModelTransition).to receive_messages(columns_hash:
                                           { 'metadata' => metadata_column })
        if ::ActiveRecord.respond_to?(:gem_version) &&
           ::ActiveRecord.gem_version >= Gem::Version.new('4.2.0.a')
          serialized_type = ::ActiveRecord::Type::Serialized.new(
            '', ::ActiveRecord::Coders::JSON
          )
          expect(metadata_column)
            .to receive(:cast_type)
            .and_return(serialized_type)
        else
          expect(MyActiveRecordModelTransition)
            .to receive_messages(serialized_attributes: { 'metadata' => '' })
        end
      end

      it "raises an exception" do
        expect do
          described_class.new(MyActiveRecordModelTransition,
                              MyActiveRecordModel, observer)
        end.to raise_exception(Statesman::IncompatibleSerializationError)
      end
    end
  end

  describe "#create" do
    let!(:adapter) do
      described_class.new(MyActiveRecordModelTransition, model, observer)
    end
    let(:from) { :x }
    let(:to) { :y }
    let(:create) { adapter.create(from, to) }
    subject { -> { create } }

    context "when there is a race" do
      it "raises a TransitionConflictError" do
        adapter2 = adapter.dup
        adapter2.create(:x, :y)
        adapter.last
        adapter2.create(:y, :z)
        expect { adapter.create(:y, :z) }
          .to raise_exception(Statesman::TransitionConflictError)
      end
    end

    context "when other exceptions occur" do
      before do
        allow_any_instance_of(MyActiveRecordModelTransition)
          .to receive(:save!).and_raise(error)
      end

      context "ActiveRecord::RecordNotUnique unrelated to this transition" do
        let(:error) { ActiveRecord::RecordNotUnique.new("unrelated", nil) }
        it { is_expected.to raise_exception(ActiveRecord::RecordNotUnique) }
      end

      context "other errors" do
        let(:error) { StandardError }
        it { is_expected.to raise_exception(StandardError) }
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
        expect_any_instance_of(MyActiveRecordModel)
          .to receive(:my_active_record_model_transitions).never
        adapter.last
      end

      context "and a new transition" do
        before { adapter.create(:y, :z, []) }
        it "retrieves the new transition from the database" do
          expect(adapter.last.to_state).to eq("z")
        end
      end
    end

    context "with a pre-fetched transition history" do
      before do
        adapter.create(:x, :y)
        model.my_active_record_model_transitions.load_target
      end

      it "doesn't query the database" do
        expect(MyActiveRecordModelTransition).not_to receive(:connection)
        expect(adapter.last.to_state).to eq("y")
      end
    end
  end
end
