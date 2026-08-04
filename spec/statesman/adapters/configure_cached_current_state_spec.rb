# frozen_string_literal: true

describe Statesman::Adapters::ConfigureCachedCurrentState, :active_record do
  before do
    prepare_model_table
    prepare_transitions_table

    Statesman.configure do
      storage_adapter(Statesman::Adapters::ActiveRecord)
    end

    MyActiveRecordModel.extend Statesman::Adapters::TypeSafeActiveRecordQueries
    MyActiveRecordModel.send(:include, described_class)
  end

  after do
    Statesman.configure { storage_adapter(Statesman::Adapters::Memory) }
    MyActiveRecordModel.reset_callbacks(:create)
  end

  def configure(**args)
    MyActiveRecordModel.configure_state_machine(
      transition_class: MyActiveRecordModelTransition,
      initial_state: :initial,
      **args,
    )
  end

  describe "including the module without calling configure_cached_current_state" do
    it "does not add any callbacks" do
      configure

      expect { MyActiveRecordModel.create }.
        to_not change(MyActiveRecordModelTransition, :count)
    end
  end

  describe ".configure_cached_current_state" do
    it "raises if transition_class was not configured" do
      klass = Class.new
      klass.send(:extend, Statesman::Adapters::TypeSafeActiveRecordQueries)
      klass.send(:include, described_class)

      expect { klass.configure_cached_current_state }.
        to raise_error(ArgumentError, /transition_class/)
    end

    it "sets the column to the initial state on create" do
      configure
      MyActiveRecordModel.configure_cached_current_state

      model = MyActiveRecordModel.create

      expect(model.cached_current_state).to eq("initial")
    end

    it "does not override an explicitly-set column value on create" do
      configure
      MyActiveRecordModel.configure_cached_current_state

      model = MyActiveRecordModel.create(cached_current_state: "succeeded")

      expect(model.reload.cached_current_state).to eq("succeeded")
    end

    it "updates the column on every transition" do
      configure
      MyActiveRecordModel.configure_cached_current_state

      model = MyActiveRecordModel.create
      model.state_machine.transition_to!(:succeeded)

      expect(model.reload.cached_current_state).to eq("succeeded")
    end

    it "writes via update_columns, not updating updated_at by default" do
      configure
      MyActiveRecordModel.configure_cached_current_state

      model = MyActiveRecordModel.create
      original_updated_at = model.updated_at

      Timecop.travel(1.hour.from_now) do
        model.state_machine.transition_to!(:succeeded)
      end

      expect(model.reload.updated_at).to be_within(1.second).of(original_updated_at)
    end

    it "touches updated_at when touch_updated_at is true" do
      configure
      MyActiveRecordModel.configure_cached_current_state(touch_updated_at: true)

      model = MyActiveRecordModel.create
      original_updated_at = model.updated_at

      Timecop.travel(1.hour.from_now) do
        model.state_machine.transition_to!(:succeeded)
      end

      expect(model.reload.updated_at).to be > original_updated_at
    end

    it "respects a custom column" do
      MyActiveRecordModel.connection.add_column(:my_active_record_models, :cached_state, :string)
      MyActiveRecordModel.reset_column_information

      configure
      MyActiveRecordModel.configure_cached_current_state(column: :cached_state)

      model = MyActiveRecordModel.create
      model.state_machine.transition_to!(:succeeded)

      expect(model.reload.cached_state).to eq("succeeded")
    end

    it "exposes the configured column name via cached_state_column_name" do
      configure
      MyActiveRecordModel.configure_cached_current_state(column: :cached_state)

      expect(MyActiveRecordModel.cached_state_column_name).to eq(:cached_state)
    end

    it "raises at transition time if the configured column doesn't exist" do
      configure
      MyActiveRecordModel.configure_cached_current_state(column: :not_a_real_column)

      model = MyActiveRecordModel.create

      expect { model.state_machine.transition_to!(:succeeded) }.
        to raise_error(ArgumentError, /not_a_real_column/)
    end

    it "does not update the cache for a transition row created directly, bypassing the machine" do
      configure
      MyActiveRecordModel.configure_cached_current_state

      model = MyActiveRecordModel.create
      model.my_active_record_model_transitions.create!(to_state: "succeeded", sort_key: 1, most_recent: true)

      expect(model.reload.cached_current_state).to eq("initial")
    end

    it "runs before the machine's own after_transition callbacks" do
      seen_cached_state = nil
      MyStateMachine.after_transition { |parent, _t| seen_cached_state = parent.cached_current_state }

      configure
      MyActiveRecordModel.configure_cached_current_state

      model = MyActiveRecordModel.create
      model.state_machine.transition_to!(:succeeded)

      expect(seen_cached_state).to eq("succeeded")
    ensure
      MyStateMachine.class_eval { callbacks[:after] = [] }
    end

    context "with a model driven by more than one machine class (no single state_machine_class)" do
      it "still updates the cache" do
        configure
        MyActiveRecordModel.configure_cached_current_state

        model = MyActiveRecordModel.create
        # Simulate a different machine class than `state_machine` normally uses - the
        # cache write happens in the shared adapter code, not per Machine subclass, so
        # it doesn't matter which machine class drove the transition.
        other_machine = MyStateMachine.new(model, transition_class: MyActiveRecordModelTransition)
        other_machine.transition_to!(:failed)

        expect(model.reload.cached_current_state).to eq("failed")
      end
    end
  end
end
