require "spec_helper"
require "timecop"
require "statesman/adapters/shared_examples"
require "statesman/exceptions"

describe Statesman::Adapters::ActiveRecord, active_record: true do
  before do
    prepare_model_table
    prepare_transitions_table
  end

  before { MyActiveRecordModelTransition.serialize(:metadata, JSON) }

  let(:observer) { double(Statesman::Machine, execute: nil) }
  let(:model) { MyActiveRecordModel.create(current_state: :pending) }

  it_behaves_like "an adapter", described_class, MyActiveRecordModelTransition

  describe "#initialize" do
    context "with unserialized metadata and non json column type" do
      before do
        metadata_column = double
        allow(metadata_column).to receive_messages(sql_type: "")
        allow(MyActiveRecordModelTransition).to receive_messages(columns_hash:
                                           { "metadata" => metadata_column })
        if ::ActiveRecord.respond_to?(:gem_version) &&
            ::ActiveRecord.gem_version >= Gem::Version.new("4.2.0.a")
          expect(MyActiveRecordModelTransition).
            to receive(:type_for_attribute).with("metadata").
            and_return(ActiveRecord::Type::Value.new)
        else
          expect(MyActiveRecordModelTransition).
            to receive_messages(serialized_attributes: {})
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
        allow(metadata_column).to receive_messages(sql_type: "json")
        allow(MyActiveRecordModelTransition).to receive_messages(columns_hash:
                                           { "metadata" => metadata_column })
        if ::ActiveRecord.respond_to?(:gem_version) &&
            ::ActiveRecord.gem_version >= Gem::Version.new("4.2.0.a")
          serialized_type = ::ActiveRecord::Type::Serialized.new(
            "", ::ActiveRecord::Coders::JSON
          )
          expect(MyActiveRecordModelTransition).
            to receive(:type_for_attribute).with("metadata").
            and_return(serialized_type)
        else
          expect(MyActiveRecordModelTransition).
            to receive_messages(serialized_attributes: { "metadata" => "" })
        end
      end

      it "raises an exception" do
        expect do
          described_class.new(MyActiveRecordModelTransition,
                              MyActiveRecordModel, observer)
        end.to raise_exception(Statesman::IncompatibleSerializationError)
      end
    end

    context "with serialized metadata and jsonb column type" do
      before do
        metadata_column = double
        allow(metadata_column).to receive_messages(sql_type: "jsonb")
        allow(MyActiveRecordModelTransition).to receive_messages(columns_hash:
                                           { "metadata" => metadata_column })
        if ::ActiveRecord.respond_to?(:gem_version) &&
            ::ActiveRecord.gem_version >= Gem::Version.new("4.2.0.a")
          serialized_type = ::ActiveRecord::Type::Serialized.new(
            "", ::ActiveRecord::Coders::JSON
          )
          expect(MyActiveRecordModelTransition).
            to receive(:type_for_attribute).with("metadata").
            and_return(serialized_type)
        else
          expect(MyActiveRecordModelTransition).
            to receive_messages(serialized_attributes: { "metadata" => "" })
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
    subject { -> { create } }

    let!(:adapter) do
      described_class.new(MyActiveRecordModelTransition, model, observer)
    end
    let(:from) { :x }
    let(:to) { :y }
    let(:create) { adapter.create(from, to) }

    context "when there is a race" do
      it "raises a TransitionConflictError" do
        adapter2 = adapter.dup
        adapter2.create(:x, :y)
        adapter.last
        adapter2.create(:y, :z)
        expect { adapter.create(:y, :z) }.
          to raise_exception(Statesman::TransitionConflictError)
      end
    end

    context "when other exceptions occur" do
      before do
        allow_any_instance_of(MyActiveRecordModelTransition).
          to receive(:save!).and_raise(error)
      end

      context "ActiveRecord::RecordNotUnique unrelated to this transition" do
        let(:error) do
          if ::ActiveRecord.respond_to?(:gem_version) &&
              ::ActiveRecord.gem_version >= Gem::Version.new("4.0.0")
            ActiveRecord::RecordNotUnique.new("unrelated")
          else
            ActiveRecord::RecordNotUnique.new("unrelated", nil)
          end
        end

        it { is_expected.to raise_exception(ActiveRecord::RecordNotUnique) }
      end

      context "other errors" do
        let(:error) { StandardError }

        it { is_expected.to raise_exception(StandardError) }
      end
    end

    describe "updating the most_recent column" do
      subject { create }

      context "with no previous transition" do
        its(:most_recent) { is_expected.to eq(true) }
      end

      context "with a previous transition" do
        let!(:previous_transition) { adapter.create(from, to) }

        its(:most_recent) { is_expected.to eq(true) }

        it "updates the previous transition's most_recent flag" do
          expect { create }.
            to change { previous_transition.reload.most_recent }.
            from(true).to be_falsey
        end

        it "touches the previous transition's updated_at timestamp" do
          expect { Timecop.freeze(Time.now + 5.seconds) { create } }.
            to(change { previous_transition.reload.updated_at })
        end

        context "for a transition class without an updated timestamp column attribute" do
          let!(:adapter) do
            described_class.new(MyActiveRecordModelTransitionWithoutInclude,
                                model,
                                observer)
          end

          it "defaults to touching the previous transition's updated_at timestamp" do
            expect { Timecop.freeze(Time.now + 5.seconds) { create } }.
              to(change { previous_transition.reload.updated_at })
          end
        end

        context "with a custom updated timestamp column set" do
          around do |example|
            MyActiveRecordModelTransition.updated_timestamp_column.tap do |original_value|
              MyActiveRecordModelTransition.updated_timestamp_column = :updated_on
              example.run
              MyActiveRecordModelTransition.updated_timestamp_column = original_value
            end
          end

          it "touches the previous transition's updated_on timestamp" do
            expect { Timecop.freeze(Time.now + 1.day) { create } }.
              to(change { previous_transition.reload.updated_on })
          end

          it "doesn't update the updated_at column" do
            expect { Timecop.freeze(Time.now + 5.seconds) { create } }.
              to_not(change { previous_transition.reload.updated_at })
          end
        end

        context "with no updated timestamp column set" do
          around do |example|
            MyActiveRecordModelTransition.updated_timestamp_column.tap do |original_value|
              MyActiveRecordModelTransition.updated_timestamp_column = nil
              example.run
              MyActiveRecordModelTransition.updated_timestamp_column = original_value
            end
          end

          it "just updates the most_recent" do
            expect { Timecop.freeze(Time.now + 5.seconds) { create } }.
              to(change { previous_transition.reload.most_recent })
          end

          it "doesn't update the updated_at column" do
            expect { Timecop.freeze(Time.now + 5.seconds) { create } }.
              to_not(change { previous_transition.reload.updated_at })
          end
        end

        context "and a query on the parent model's state is made" do
          context "in a before action" do
            it "still has the old state" do
              allow(observer).to receive(:execute) do |phase|
                next unless phase == :before

                expect(
                  model.transitions.where(most_recent: true).first.to_state,
                ).to eq("y")
              end

              adapter.create(:y, :z)
            end
          end

          context "in an after action" do
            it "still has the old state" do
              allow(observer).to receive(:execute) do |phase|
                next unless phase == :after

                expect(
                  model.transitions.where(most_recent: true).first.to_state,
                ).to eq("z")
              end

              adapter.create(:y, :z)
            end
          end
        end
      end

      context "with two previous transitions" do
        let!(:previous_transition) { adapter.create(from, to) }
        let!(:another_previous_transition) { adapter.create(from, to) }

        its(:most_recent) { is_expected.to eq(true) }

        it "updates the previous transition's most_recent flag" do
          expect { create }.
            to change { another_previous_transition.reload.most_recent }.
            from(true).to be_falsey
        end
      end
    end
  end

  describe "#last" do
    let(:adapter) do
      described_class.new(MyActiveRecordModelTransition, model, observer)
    end

    before { adapter.create(:x, :y) }

    context "with a previously looked up transition" do
      before { adapter.last }

      it "caches the transition" do
        expect_any_instance_of(MyActiveRecordModel).
          to_not receive(:my_active_record_model_transitions)
        adapter.last
      end

      context "after then creating a new transition" do
        before { adapter.create(:y, :z, []) }

        it "retrieves the new transition from the database" do
          expect(adapter.last.to_state).to eq("z")
        end
      end

      context "when a new transition has been created elsewhere" do
        let(:alternate_adapter) do
          described_class.new(MyActiveRecordModelTransition, model, observer)
        end

        it "still returns the cached value" do
          alternate_adapter.create(:y, :z, [])

          expect_any_instance_of(MyActiveRecordModel).
            to_not receive(:my_active_record_model_transitions)
          expect(adapter.last.to_state).to eq("y")
        end

        context "when explicitly not using the cache" do
          context "when the transitions are in memory" do
            before do
              model.my_active_record_model_transitions.load
              alternate_adapter.create(:y, :z, [])
            end

            it "reloads the value" do
              expect(adapter.last(force_reload: true).to_state).to eq("z")
            end
          end

          context "when the transitions are not in memory" do
            before do
              model.my_active_record_model_transitions.reset
              alternate_adapter.create(:y, :z, [])
            end

            it "reloads the value" do
              expect(adapter.last(force_reload: true).to_state).to eq("z")
            end
          end
        end
      end
    end

    context "with a pre-fetched transition history" do
      before { adapter.create(:x, :y) }

      before { model.my_active_record_model_transitions.load_target }

      it "doesn't query the database" do
        expect(MyActiveRecordModelTransition).to_not receive(:connection)
        expect(adapter.last.to_state).to eq("y")
      end
    end
  end

  context "with a namespaced model" do
    before do
      CreateNamespacedARModelMigration.migrate(:up)
      CreateNamespacedARModelTransitionMigration.migrate(:up)
    end

    before do
      MyNamespace::MyActiveRecordModelTransition.serialize(:metadata, JSON)
    end

    let(:observer) { double(Statesman::Machine, execute: nil) }
    let(:model) do
      MyNamespace::MyActiveRecordModel.create(current_state: :pending)
    end

    it_behaves_like "an adapter",
                    described_class, MyNamespace::MyActiveRecordModelTransition,
                    association_name: :my_active_record_model_transitions
  end
end
