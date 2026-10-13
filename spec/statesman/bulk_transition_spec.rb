# frozen_string_literal: true

require "spec_helper"

describe Statesman::BulkTransition, :active_record do
  before do
    # The shared MyActiveRecordModel fixture is wired via the older
    # `include ActiveRecordQueries[...]` form, which doesn't define `.transition_class`.
    # BulkTransition relies on the newer `configure_state_machine` convention (the same
    # one `configure_cached_current_state` requires), so configure it here once.
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

    it "raises TransitionConflictError and rolls the whole batch back on a conflicting row" do
      ok = create_model.id
      conflicted = create_model.id
      # An out-of-band row occupying the sort_key the new transition would take.
      not_current = MyActiveRecordModelTransition.columns_hash["most_recent"].null ? nil : false
      MyActiveRecordModelTransition.create!(
        my_active_record_model_id: conflicted, to_state: "failed", sort_key: 20,
        most_recent: not_current, metadata: {}
      )
      bulk = described_class.new(
        model_class: MyActiveRecordModel, machine_class: machine_class,
        from: :initial, to: :succeeded
      )

      expect { bulk.call!([ok, conflicted]) }.to raise_error(Statesman::TransitionConflictError)

      expect(MyActiveRecordModelTransition.where(my_active_record_model_id: [ok, conflicted], most_recent: true).
        pluck(:to_state)).to eq(%w[initial initial])
    end

    it "marks flipped rows as not current the same way the single path does" do
      ids = Array.new(2) { create_model.id }
      bulk = described_class.new(
        model_class: MyActiveRecordModel, machine_class: machine_class,
        from: :initial, to: :succeeded
      )
      bulk.call!(ids)

      # NULL when the column is nullable (needed for the unique index on databases
      # without partial indexes, e.g. MySQL), false otherwise.
      expected = MyActiveRecordModelTransition.columns_hash["most_recent"].null ? nil : false
      old_rows = MyActiveRecordModelTransition.where(my_active_record_model_id: ids, to_state: "initial")

      expect(old_rows.map(&:most_recent)).to all(eq(expected))
      expect(MyActiveRecordModelTransition.where(my_active_record_model_id: ids, most_recent: true).count).
        to eq(ids.size)
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

    describe "flip query RETURNING clause" do
      def flip_sql_for(bulk, id, **options)
        statements = []
        subscriber = ->(*, payload) do
          statements << payload[:sql] if /\AUPDATE\s+"?my_active_record_model_transitions/i.match?(payload[:sql])
        end
        ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
          bulk.call!([id], **options)
        end
        statements.find { |sql| sql.include?("most_recent = FALSE") || sql.include?("most_recent = false") }
      end

      let(:bulk) do
        described_class.new(
          model_class: MyActiveRecordModel, machine_class: machine_class,
          from: :initial, to: :succeeded
        )
      end

      it "returns only the carried columns, not *" do
        skip "RETURNING is PostgreSQL-only" unless postgres? # rubocop:disable RSpec/Pending
        id = create_model(extra_data: "x").id
        sql = flip_sql_for(bulk, id, attributes_to_copy: ["extra_data"])
        returning = sql[/RETURNING (.*)\z/m, 1]

        expect(sql).to_not include("RETURNING *")
        expect(returning.split(", ")).to contain_exactly(
          '"my_active_record_model_id"', '"sort_key"', '"extra_data"'
        )
      end

      it "does not return columns that were not requested" do
        skip "RETURNING is PostgreSQL-only" unless postgres? # rubocop:disable RSpec/Pending
        id = create_model(extra_data: "x").id
        sql = flip_sql_for(bulk, id, attributes_to_copy: [])

        expect(sql[/RETURNING (.*)\z/m, 1]).to_not include("extra_data")
      end
    end

    it "raises ValidationError for unknown attributes_to_copy columns" do
      id = create_model.id
      bulk = described_class.new(
        model_class: MyActiveRecordModel, machine_class: machine_class,
        from: :initial, to: :succeeded
      )

      expect do
        bulk.call!([id], attributes_to_copy: ["not_a_real_column"])
      end.to raise_error(Statesman::BulkTransition::ValidationError, /not_a_real_column/)
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
      end.to raise_error(Statesman::BulkTransition::ValidationError, /not_a_real_column/)
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
