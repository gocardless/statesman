# frozen_string_literal: true

require "spec_helper"

describe Statesman::BulkTransition::V1, :active_record do
  before do
    # The shared MyActiveRecordModel fixture is wired via the older
    # `include ActiveRecordQueries[...]` form, which doesn't define `.transition_class`.
    # BulkTransition relies on the newer `configure_state_machine` convention (the same
    # one `configure_cached_current_state` requires), so configure it here once. This
    # runs regardless of adapter: the non-Postgres context below also needs
    # `model_class.transition_class` to resolve, since V1#initialize reads it before
    # it gets a chance to raise UnsupportedAdapterError.
    unless MyActiveRecordModel.respond_to?(:transition_class)
      MyActiveRecordModel.extend(Statesman::Adapters::TypeSafeActiveRecordQueries)
      MyActiveRecordModel.configure_state_machine(
        transition_class: MyActiveRecordModelTransition, initial_state: :initial,
      )
    end

    unless MyActiveRecordModel.respond_to?(:cached_state_column_name)
      MyActiveRecordModel.include(Statesman::Adapters::ConfigureCachedCurrentState)
      MyActiveRecordModel.configure_cached_current_state
    end

    next unless postgres?

    prepare_model_table
    prepare_transitions_table

    # Other specs redefine MyActiveRecordModel.transition_class without restoring it, so
    # pin it here to stay independent of spec ordering.
    allow(MyActiveRecordModel).to receive(:transition_class).
      and_return(MyActiveRecordModelTransition)

    # Add a free business column (not one of AR's "magic" created_on/updated_on/etc.
    # timestamp columns, which insert_all auto-populates regardless of row content) so
    # attributes_to_copy has something meaningful to carry forward in this spec.
    ActiveRecord::Base.connection.execute(
      "ALTER TABLE my_active_record_model_transitions ADD COLUMN extra_data text",
    )
    MyActiveRecordModelTransition.reset_column_information
  end

  # V1 is explicitly Postgres-only (see UnsupportedAdapterError in the class itself).
  # CI runs this whole suite three times - sqlite (default), postgres, mysql - so the
  # Postgres-specific examples below are only defined at all when running under
  # Postgres (checked at file-load time, same as postgres?/mysql?/sqlite? elsewhere in
  # this gem's own specs). The "on a non-Postgres adapter" context after this `if` is
  # the one thing that should run everywhere else instead.
  if postgres?
    let(:machine_class) { MyStateMachine }

    def create_model(initial_state: "initial", extra_data: nil)
      model = MyActiveRecordModel.create!
      model.my_active_record_model_transitions.create!(
        to_state: initial_state, sort_key: 10, most_recent: true, metadata: {},
        extra_data: extra_data
      )
      model
    end

    def last_transition_for(id)
      MyActiveRecordModel.find(id).my_active_record_model_transitions.order(:sort_key).last
    end

    describe "#call!" do
      it "transitions only the parents currently in the from state" do
        in_initial = Array.new(3) { create_model.id }
        in_succeeded = create_model(initial_state: "succeeded").id

        bulk = described_class.new(
          model_class: MyActiveRecordModel, machine_class: machine_class,
          from: :initial, to: :succeeded
        )
        transitioned = bulk.call!(in_initial + [in_succeeded], metadata: { "foo" => "bar" })

        expect(transitioned).to match_array(in_initial)
      end

      it "applies the metadata and most_recent flag to each transitioned parent" do
        in_initial = Array.new(3) { create_model.id }
        bulk = described_class.new(
          model_class: MyActiveRecordModel, machine_class: machine_class,
          from: :initial, to: :succeeded
        )
        bulk.call!(in_initial, metadata: { "foo" => "bar" })

        MyActiveRecordModel.where(id: in_initial).each do |model|
          last = model.my_active_record_model_transitions.order(:sort_key).last
          expect(last.to_state).to eq("succeeded")
          expect(last.most_recent).to be(true)
          expect(last.metadata).to eq({ "foo" => "bar" })
        end
      end

      it "leaves parents not currently in the from state untouched" do
        in_succeeded = create_model(initial_state: "succeeded").id
        bulk = described_class.new(
          model_class: MyActiveRecordModel, machine_class: machine_class,
          from: :initial, to: :succeeded
        )
        bulk.call!([in_succeeded], metadata: { "foo" => "bar" })

        expect(last_transition_for(in_succeeded).sort_key).to eq(10)
      end

      it "is idempotent - re-running skips parents no longer in the from state" do
        ids = Array.new(2) { create_model.id }
        bulk = described_class.new(
          model_class: MyActiveRecordModel, machine_class: machine_class,
          from: :initial, to: :succeeded
        )

        first_run = bulk.call!(ids)
        second_run = bulk.call!(ids)

        expect(first_run).to match_array(ids)
        expect(second_run).to eq([])
      end

      it "flips the old most_recent row off and sets sort_key = old + 10" do
        id = create_model.id
        bulk = described_class.new(
          model_class: MyActiveRecordModel, machine_class: machine_class,
          from: :initial, to: :succeeded
        )
        bulk.call!([id])

        transitions = MyActiveRecordModel.find(id).
          my_active_record_model_transitions.order(:sort_key)
        expect(transitions.map(&:most_recent)).to eq([false, true])
        expect(transitions.map(&:sort_key)).to eq([10, 20])
      end

      it "carries forward only explicitly requested attributes_to_copy" do
        id = create_model(extra_data: "keep-me").id
        bulk = described_class.new(
          model_class: MyActiveRecordModel, machine_class: machine_class,
          from: :initial, to: :succeeded
        )
        bulk.call!([id], attributes_to_copy: ["extra_data"])

        expect(last_transition_for(id).extra_data).to eq("keep-me")
      end

      it "does not carry forward attributes that weren't requested" do
        id = create_model(extra_data: "should-not-persist").id
        bulk = described_class.new(
          model_class: MyActiveRecordModel, machine_class: machine_class,
          from: :initial, to: :succeeded
        )
        bulk.call!([id]) # no attributes_to_copy

        expect(last_transition_for(id).extra_data).to be_nil
      end

      it "raises ValidationError for unknown attributes_to_copy columns" do
        id = create_model.id
        bulk = described_class.new(
          model_class: MyActiveRecordModel, machine_class: machine_class,
          from: :initial, to: :succeeded
        )

        expect do
          bulk.call!([id], attributes_to_copy: ["not_a_real_column"])
        end.to raise_error(Statesman::BulkTransition::V1::ValidationError, /not_a_real_column/)
      end

      it "raises InvalidTransitionError for a from/to pair the machine doesn't allow" do
        expect do
          described_class.new(
            model_class: MyActiveRecordModel, machine_class: machine_class,
            from: :succeeded, to: :succeeded
          )
        end.to raise_error(Statesman::InvalidTransitionError)
      end

      it "runs the block inside the transaction and rolls back everything if it raises" do
        id = create_model.id
        bulk = described_class.new(
          model_class: MyActiveRecordModel, machine_class: machine_class,
          from: :initial, to: :succeeded
        )

        expect do
          bulk.call!([id]) { |_rows| raise "boom" }
        end.to raise_error("boom")

        last = last_transition_for(id)
        expect(last.to_state).to eq("initial")
        expect(last.most_recent).to be(true)
      end

      it "yields the inserted rows to the block" do
        id = create_model.id
        bulk = described_class.new(
          model_class: MyActiveRecordModel, machine_class: machine_class,
          from: :initial, to: :succeeded
        )

        yielded = nil
        bulk.call!([id]) { |rows| yielded = rows }

        expect(yielded.length).to eq(1)
        expect(yielded.first["to_state"]).to eq("succeeded")
      end

      it "invokes a callback object's #call via normal method dispatch, not bare yield" do
        id = create_model.id
        bulk = described_class.new(
          model_class: MyActiveRecordModel, machine_class: machine_class,
          from: :initial, to: :succeeded
        )
        callback = ->(_rows) {}

        expect(callback).to receive(:call).once.and_call_original

        bulk.call!([id], &callback)
      end

      it "returns an empty array and does nothing for an empty id list" do
        bulk = described_class.new(
          model_class: MyActiveRecordModel, machine_class: machine_class,
          from: :initial, to: :succeeded
        )
        expect(bulk.call!([])).to eq([])
      end

      it "overrides metadata per-parent via metadata_per_id, falling back to the uniform metadata" do
        overridden_id = create_model.id
        default_id = create_model.id
        bulk = described_class.new(
          model_class: MyActiveRecordModel, machine_class: machine_class,
          from: :initial, to: :succeeded
        )

        bulk.call!(
          [overridden_id, default_id],
          metadata: { "origin" => "gocardless" },
          metadata_per_id: { overridden_id => { "origin" => "api" } },
        )

        expect(last_transition_for(overridden_id).metadata).to eq({ "origin" => "api" })
        expect(last_transition_for(default_id).metadata).to eq({ "origin" => "gocardless" })
      end

      it "overrides a copied attribute per-parent via attributes_per_id" do
        overridden_id = create_model(extra_data: "from-previous-row").id
        default_id = create_model(extra_data: "from-previous-row").id
        bulk = described_class.new(
          model_class: MyActiveRecordModel, machine_class: machine_class,
          from: :initial, to: :succeeded
        )

        bulk.call!(
          [overridden_id, default_id],
          attributes_to_copy: ["extra_data"],
          attributes_per_id: { overridden_id => { "extra_data" => "looked-up-value" } },
        )

        expect(last_transition_for(overridden_id).extra_data).to eq("looked-up-value")
        expect(last_transition_for(default_id).extra_data).to eq("from-previous-row")
      end

      it "yields only attributes_for_callback when given, instead of the attributes_to_copy default" do
        id = create_model(extra_data: "keep-me").id
        bulk = described_class.new(
          model_class: MyActiveRecordModel, machine_class: machine_class,
          from: :initial, to: :succeeded
        )

        yielded = nil
        bulk.call!(
          [id], attributes_to_copy: ["extra_data"],
                attributes_for_callback: %w[my_active_record_model_id to_state metadata]
        ) { |rows| yielded = rows }

        expect(yielded.first.keys).to match_array(%w[my_active_record_model_id to_state metadata])
      end

      it "raises ValidationError for unknown attributes_for_callback columns" do
        id = create_model.id
        bulk = described_class.new(
          model_class: MyActiveRecordModel, machine_class: machine_class,
          from: :initial, to: :succeeded
        )

        expect do
          bulk.call!([id], attributes_for_callback: ["not_a_real_column"])
        end.to raise_error(Statesman::BulkTransition::V1::ValidationError, /not_a_real_column/)
      end
    end

    describe "cached_current_state integration" do
      it "bulk-updates the cached column for every transitioned parent" do
        ids = Array.new(2) { create_model.id }
        bulk = described_class.new(
          model_class: MyActiveRecordModel, machine_class: machine_class,
          from: :initial, to: :succeeded
        )
        bulk.call!(ids)

        MyActiveRecordModel.where(id: ids).each do |model|
          expect(model.cached_current_state).to eq("succeeded")
        end
      end
    end
  end

  context "on a non-PostgreSQL adapter" do
    before { skip "only relevant on non-Postgres adapters" if postgres? } # rubocop:disable RSpec/Pending

    it "raises UnsupportedAdapterError instead of silently producing wrong SQL" do
      expect do
        described_class.new(
          model_class: MyActiveRecordModel, machine_class: MyStateMachine,
          from: :initial, to: :succeeded
        )
      end.to raise_error(described_class::UnsupportedAdapterError, /only supports PostgreSQL/)
    end
  end
end
