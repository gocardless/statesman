# frozen_string_literal: true

# End-to-end equivalence spec for the WU3 DoD: a batch of Statesman::BulkTransition.call
# against the real ActiveRecord adapter must produce the same final state as a loop of
# #transition_to! — same history, most_recent, sort_key spacing, and (where configured)
# cached current-state column, including after_commit's deferred-until-real-commit
# timing (see "after_commit transactional integrity" below). Unit-level AR mechanics
# (conflicts, races, sort_key batching) are covered in
# spec/statesman/adapters/active_record_bulk_create_spec.rb; this file checks end-to-end
# equivalence claims that need the real Machine/BulkTransition/Adapters::ActiveRecord
# stack together, not just BuildTransitions/BulkCreate in isolation.
describe "BulkTransition.call vs a loop of #transition_to!", # rubocop:disable RSpec/DescribeClass
         :active_record do
  before do
    prepare_model_table
    prepare_transitions_table

    Statesman.configure do
      storage_adapter(Statesman::Adapters::ActiveRecord)
    end
  end

  after { Statesman.configure { storage_adapter(Statesman::Adapters::Memory) } }

  let(:machine_class) do
    Class.new do
      include Statesman::Machine

      def self.name
        "MyBulkEquivalenceStateMachine"
      end

      state :pending, initial: true
      state :processing
      transition from: :pending, to: :processing
    end
  end
  let(:round_trip_machine_class) do
    Class.new do
      include Statesman::Machine

      def self.name
        "MyBulkEquivalenceRoundTripStateMachine"
      end

      state :pending, initial: true
      state :processing
      transition from: :pending, to: :processing
      transition from: :processing, to: :pending
    end
  end

  def build_models(count)
    Array.new(count) { MyActiveRecordModel.create(current_state: "pending") }
  end

  def item_for(machine, metadata: {})
    Statesman::BulkTransition::Item.new(machine: machine, metadata: metadata)
  end

  def history_snapshot(model)
    model.reload.my_active_record_model_transitions.order(:sort_key).map do |transition|
      transition.attributes.except("id", "my_active_record_model_id", "created_at", "updated_at")
    end
  end

  it "produces identical final history, most_recent, and sort_key spacing" do
    looped = build_models(3)
    bulked = build_models(3)

    looped.each do |model|
      machine_class.new(model, transition_class: MyActiveRecordModelTransition).transition_to!(:processing)
    end
    Statesman::BulkTransition.call(
      bulked.map { |model| item_for(machine_class.new(model, transition_class: MyActiveRecordModelTransition)) },
      from_state: :pending, to_state: :processing,
    )

    looped.zip(bulked).each do |loop_model, bulk_model|
      expect(history_snapshot(bulk_model)).to eq(history_snapshot(loop_model))
    end
  end

  it "bases sort_key on prior history identically for both paths" do
    model_looped = MyActiveRecordModel.create(current_state: "pending")
    model_bulked = MyActiveRecordModel.create(current_state: "pending")
    [model_looped, model_bulked].each do |model|
      machine = round_trip_machine_class.new(model, transition_class: MyActiveRecordModelTransition)
      machine.transition_to!(:processing)
      machine.transition_to!(:pending)
    end

    round_trip_machine_class.new(model_looped, transition_class: MyActiveRecordModelTransition).
      transition_to!(:processing)
    Statesman::BulkTransition.call(
      [item_for(round_trip_machine_class.new(model_bulked, transition_class: MyActiveRecordModelTransition))],
      from_state: :pending, to_state: :processing,
    )

    expect(history_snapshot(model_bulked)).to eq(history_snapshot(model_looped))
  end

  context "with the cached current state column configured" do
    before do
      MyActiveRecordModel.extend Statesman::Adapters::TypeSafeActiveRecordQueries
      MyActiveRecordModel.include Statesman::Adapters::ConfigureCachedCurrentState
      MyActiveRecordModel.configure_state_machine(transition_class: MyActiveRecordModelTransition,
                                                  initial_state: :pending)
      MyActiveRecordModel.configure_cached_current_state
    end

    after { MyActiveRecordModel.reset_callbacks(:create) }

    it "updates the cached column identically to the single-object path" do
      looped = build_models(2)
      bulked = build_models(2)

      looped.each do |model|
        machine_class.new(model, transition_class: MyActiveRecordModelTransition).transition_to!(:processing)
      end
      Statesman::BulkTransition.call(
        bulked.map { |model| item_for(machine_class.new(model, transition_class: MyActiveRecordModelTransition)) },
        from_state: :pending, to_state: :processing,
      )

      expect(bulked.map { |m| m.reload.cached_current_state }).to eq(looped.map { |m| m.reload.cached_current_state })
      expect(bulked.map { |m| m.reload.cached_current_state }).to all(eq("processing"))
    end
  end

  # BulkTransition dispatches after_commit itself, once .bulk_create returns (see
  # BulkTransition#defer_after_commit_callbacks) — by then, Adapters::ActiveRecord's own
  # bulk write transaction has already closed. If the caller also wraps the whole call
  # in their own outer transaction, after_commit must still wait for *that* to commit,
  # not fire the moment this adapter's own inner transaction happens to close. Both
  # paths below share one real outer transaction with the single-object path, so this
  # also demonstrates equivalence: the bulk path gets no worse (or better) a guarantee
  # than #transition_to! already has.
  describe "after_commit transactional integrity" do
    let(:after_commit_fired) { [] }

    before { machine_class.after_transition(after_commit: true) { |object, _transition| after_commit_fired << object } }

    it "fires after_commit for neither path if the real outermost transaction rolls back" do
      model_looped = MyActiveRecordModel.create(current_state: "pending")
      model_bulked = MyActiveRecordModel.create(current_state: "pending")

      expect do
        ActiveRecord::Base.transaction do
          machine_class.new(model_looped, transition_class: MyActiveRecordModelTransition).transition_to!(:processing)
          Statesman::BulkTransition.call(
            [item_for(machine_class.new(model_bulked, transition_class: MyActiveRecordModelTransition))],
            from_state: :pending, to_state: :processing,
          )
          raise ActiveRecord::Rollback
        end
      end.to_not change(after_commit_fired, :count)
    end

    it "fires after_commit for both paths once the real outermost transaction commits" do
      model_looped = MyActiveRecordModel.create(current_state: "pending")
      model_bulked = MyActiveRecordModel.create(current_state: "pending")

      ActiveRecord::Base.transaction do
        machine_class.new(model_looped, transition_class: MyActiveRecordModelTransition).transition_to!(:processing)
        Statesman::BulkTransition.call(
          [item_for(machine_class.new(model_bulked, transition_class: MyActiveRecordModelTransition))],
          from_state: :pending, to_state: :processing,
        )
        # Neither after_commit has fired yet — both are still waiting on this
        # transaction, not on whichever of their own inner transactions already closed.
        expect(after_commit_fired).to eq([])
      end

      expect(after_commit_fired).to contain_exactly(model_looped, model_bulked)
    end
  end
end
