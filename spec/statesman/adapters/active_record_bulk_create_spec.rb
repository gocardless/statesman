# frozen_string_literal: true

require "statesman/exceptions"

describe Statesman::Adapters::ActiveRecord, :active_record do
  before do
    prepare_model_table
    prepare_transitions_table

    prepare_sti_model_table
    prepare_sti_transitions_table
  end

  let(:observer) { instance_double(Statesman::Machine, execute: nil) }
  let(:no_op) { ->(_item) {} }

  def adapter_for(model, transition_class: MyActiveRecordModelTransition, association_name: nil)
    described_class.new(transition_class, model, observer, { association_name: association_name }.compact)
  end

  def item_for(model, from, to, metadata: {}, transition_class: MyActiveRecordModelTransition, association_name: nil)
    adapter = adapter_for(model, transition_class: transition_class, association_name: association_name)
    { object: model, adapter: adapter, transition: adapter.build_transition(from, to, metadata) }
  end

  describe "#build_transition" do
    subject(:transition) { adapter_for(model).build_transition("x", "y", { "some" => "hash" }) }

    let(:model) { MyActiveRecordModel.create(current_state: "x") }

    it { is_expected.to be_a(MyActiveRecordModelTransition) }
    it { is_expected.to be_new_record }
    its(:from_state) { is_expected.to eq("x") }
    its(:to_state) { is_expected.to eq("y") }
    its(:metadata) { is_expected.to eq({ "some" => "hash" }) }
    its(:sort_key) { is_expected.to be_nil }

    it "does not persist or fire any callbacks" do
      expect(observer).to_not receive(:execute)
      expect { transition }.to_not change(MyActiveRecordModelTransition, :count)
    end

    context "for an STI transition class" do
      subject(:transition) do
        adapter_for(model, transition_class: StiAActiveRecordModelTransition,
                           association_name: :sti_a_active_record_model_transitions).build_transition("x", "y")
      end

      let(:model) { StiActiveRecordModel.create }

      it { is_expected.to be_a(StiAActiveRecordModelTransition) }
      its(:type) { is_expected.to eq("StiAActiveRecordModelTransition") }
    end
  end

  describe ".bulk_create" do
    subject(:result) do
      described_class.bulk_create(items, from: from, after: after, after_commit: after_commit)
    end

    let(:from) { "x" }
    let(:after) { no_op }
    let(:after_commit) { no_op }

    context "with parents that have no prior history" do
      let(:model_a) { MyActiveRecordModel.create(current_state: "x") }
      let(:model_b) { MyActiveRecordModel.create(current_state: "x") }
      let(:items) { [item_for(model_a, "x", "y"), item_for(model_b, "x", "y")] }

      it "reports every object as successful, with no failures" do
        expect(result.successful).to eq([model_a, model_b])
        expect(result.failed).to eq([])
        expect(result.success?).to be(true)
      end

      it "persists one transition per parent, with sort_key 10" do
        result
        expect(model_a.reload.my_active_record_model_transitions.map(&:sort_key)).to eq([10])
        expect(model_b.reload.my_active_record_model_transitions.map(&:sort_key)).to eq([10])
      end

      it "sets most_recent true and the correct to_state/from_state" do
        result
        transition = model_a.reload.my_active_record_model_transitions.first
        expect(transition).to have_attributes(from_state: "x", to_state: "y", most_recent: true)
      end

      it "applies the given metadata" do
        items.each { |item| item[:transition].assign_attributes(metadata: { "k" => "v" }) }
        result
        expect(model_a.reload.my_active_record_model_transitions.first.metadata).to eq({ "k" => "v" })
      end

      context "with recording after/after_commit callables" do
        let(:calls) { [] }
        let(:after) { ->(item) { calls << [:after, item[:object], item[:transition].persisted?] } }
        let(:after_commit) { ->(item) { calls << [:after_commit, item[:object], item[:transition].persisted?] } }

        it "invokes after per item inside the transaction, then after_commit per item once it commits" do
          result

          # after_commit is registered on the connection (not called synchronously), so
          # Rails fires every registered after_commit together once the transaction
          # actually commits — after every item's `after` has already run, not
          # interleaved with them the way Adapters::Memory's immediate calls are.
          expect(calls).to eq(
            [
              [:after, model_a, true],
              [:after, model_b, true],
              [:after_commit, model_a, true],
              [:after_commit, model_b, true],
            ],
          )
        end
      end

      context "when after raises" do
        let(:after) { ->(item) { raise "boom" if item[:object] == model_b } }

        it "rolls back the whole chunk — no row is persisted for any survivor" do
          expect { result }.to raise_error("boom")
          expect(MyActiveRecordModelTransition.count).to eq(0)
        end
      end
    end

    context "with a parent that already has history" do
      let(:model) { MyActiveRecordModel.create(current_state: "x") }
      let(:items) { [item_for(model, "x", "y")] }

      before { adapter_for(model).create("w", "x") }

      it "bases the new sort_key on the prior transition's" do
        result
        expect(model.reload.my_active_record_model_transitions.order(:sort_key).map(&:sort_key)).to eq([10, 20])
      end

      it "flips the old transition's most_recent to false" do
        result
        old, new = model.reload.my_active_record_model_transitions.order(:sort_key)
        expect(old.most_recent).to be_falsey
        expect(new.most_recent).to be(true)
      end
    end

    context "when a parent's current state no longer matches the requested from state (H2)" do
      let(:model_a) { MyActiveRecordModel.create(current_state: "x") }
      let(:model_b) { MyActiveRecordModel.create(current_state: "x") }
      let(:items) { [item_for(model_a, "x", "y"), item_for(model_b, "x", "y")] }

      before do
        # model_a has already moved on to "z" by the time bulk_create is asked to
        # transition it from "x" — a stale read upstream in Machine.validate_bulk_transition.
        adapter_for(model_a).create("x", "z")
      end

      it "reports the stale parent as a conflict and still transitions the rest" do
        expect(result.successful).to eq([model_b])
        expect(result.failed.map(&:object)).to eq([model_a])
        expect(result.failed.first.reason).to eq(:conflict)
      end

      it "never inserts a row with the stale from_state" do
        result
        expect(model_a.reload.my_active_record_model_transitions.pluck(:to_state)).to eq(["z"])
      end
    end

    context "when a parent is raced between the snapshot read and the flip/insert (H1)" do
      let(:model_a) { MyActiveRecordModel.create(current_state: "x") }
      let(:model_b) { MyActiveRecordModel.create(current_state: "x") }
      let(:items) { [item_for(model_a, "x", "y"), item_for(model_b, "x", "y")] }

      before do
        adapter_for(model_a).create("w", "x")

        raced = false
        allow_any_instance_of(described_class::BulkCreate).to receive(:most_recent_rows_for).
          and_wrap_original do |original, *args|
            rows = original.call(*args)
            unless raced
              raced = true
              # A concurrent single transition lands for model_a right after the snapshot read,
              # before our flip/recheck — exactly the race window this call protects.
              adapter_for(model_a).create("x", "z")
            end
            rows
          end
      end

      it "drops only the raced parent as a conflict; the rest commit" do
        expect(result.successful).to eq([model_b])
        expect(result.failed.map(&:object)).to eq([model_a])
      end

      it "tags the race as a conflict" do
        expect(result.failed.first.reason).to eq(:conflict)
      end

      it "leaves model_a's history exactly as the racer wrote it, untouched by our attempt" do
        result
        expect(model_a.reload.my_active_record_model_transitions.order(:sort_key).map(&:to_state)).to eq(%w[x z])
      end
    end

    context "when a brand-new parent is raced between the snapshot read and the insert" do
      let(:model) { MyActiveRecordModel.create(current_state: "x") }
      let(:items) { [item_for(model, "x", "y")] }

      before do
        raced = false
        allow_any_instance_of(described_class::BulkCreate).to receive(:most_recent_rows_for).
          and_wrap_original do |original, *args|
            rows = original.call(*args)
            if rows.empty? && !raced
              raced = true
              adapter_for(model).create("x", "z")
            end
            rows
          end
      end

      it "reports a conflict instead of double-inserting the parent's first transition" do
        expect(result.successful).to eq([])
        expect(result.failed.map(&:object)).to eq([model])
        expect(result.failed.first.reason).to eq(:conflict)
      end

      it "leaves only the racer's transition in history" do
        result
        expect(model.reload.my_active_record_model_transitions.pluck(:to_state)).to eq(["z"])
      end
    end

    context "when insert_all! itself hits the final residual race window" do
      let(:model_a) { MyActiveRecordModel.create(current_state: "x") }
      let(:model_b) { MyActiveRecordModel.create(current_state: "x") }
      let(:items) { [item_for(model_a, "x", "y"), item_for(model_b, "x", "y")] }

      # A genuinely independent concurrent writer can't be simulated deterministically on
      # a single shared connection: a "racer" call nested inside our own open transaction
      # (the only way to reach this code from a single-threaded test) gets rolled back
      # *with* us when the retry's rollback happens, since savepoints aren't independent
      # of their parent transaction — so it wouldn't still be there for the retry to find.
      # Instead, this drives the same two observable events a real race would cause: (1)
      # insert_all! raises RecordNotUnique once, (2) the *retry's own* recheck finds the
      # raced parent — exactly what a real race landing in that window would produce.
      before do
        attempt = 0
        allow_any_instance_of(described_class::BulkCreate).to receive(:most_recent_rows_for).
          and_wrap_original do |original, parent_ids|
            attempt += 1
            rows = original.call(parent_ids)
            attempt == 3 ? rows.merge(model_a.id => { id: -1, sort_key: 999, to_state: "x" }) : rows
          end

        raised = false
        allow_any_instance_of(described_class::BulkCreate).to receive(:insert_survivors!).
          and_wrap_original do |original, *args|
            unless raised
              raised = true
              raise ActiveRecord::RecordNotUnique, "simulated race"
            end
            original.call(*args)
          end
      end

      it "retries the chunk, excluding whoever the retry's own recheck finds raced, and still commits the rest" do
        expect(result.successful).to eq([model_b])
        expect(result.failed.map(&:object)).to eq([model_a])
        expect(result.failed.first.reason).to eq(:conflict)
      end

      it "leaves no trace of the excluded parent's attempted transition, but keeps the survivor's" do
        result
        expect(model_b.reload.my_active_record_model_transitions.pluck(:to_state)).to eq(["y"])
        expect(model_a.reload.my_active_record_model_transitions).to be_empty
      end

      it "gives up and raises after MAX_INSERT_ATTEMPTS consecutive conflicts" do
        allow_any_instance_of(described_class::BulkCreate).to receive(:insert_survivors!).
          and_raise(ActiveRecord::RecordNotUnique, "persistent")

        expect { result }.to raise_error(ActiveRecord::RecordNotUnique)
      end
    end

    context "after_commit transactional integrity" do
      let(:model) { MyActiveRecordModel.create(current_state: "x") }
      let(:items) { [item_for(model, "x", "y")] }
      let(:after_commit_fired) { [] }
      let(:after_commit) { ->(item) { after_commit_fired << item[:object] } }

      it "does not fire after_commit if the real outermost transaction rolls back" do
        expect do
          ActiveRecord::Base.transaction do
            result
            raise ActiveRecord::Rollback
          end
        end.to_not change(after_commit_fired, :count)
      end

      it "fires after_commit once the real outermost transaction commits" do
        ActiveRecord::Base.transaction { result }
        expect(after_commit_fired).to eq([model])
      end
    end

    context "when items use different transition classes" do
      let(:model) { MyActiveRecordModel.create(current_state: "x") }
      let(:sti_model) { StiActiveRecordModel.create }
      let(:items) do
        [
          item_for(model, "x", "y"),
          item_for(sti_model, "x", "y", transition_class: StiAActiveRecordModelTransition,
                                        association_name: :sti_a_active_record_model_transitions),
        ]
      end

      it "raises instead of silently writing some items against the wrong table" do
        expect { result }.to raise_error(ArgumentError, /same.*transition class/)
      end
    end

    context "when items use different parent model classes (but share a transition class)" do
      let(:model_a) { MyActiveRecordModel.create(current_state: "x") }
      # A real Ruby subclass, not STI (my_active_record_models has no `type` column) —
      # exists purely so item[:object].class differs from model_a's while both still
      # resolve the same transition_class/association, isolating this one check.
      let(:other_model_class) { Class.new(MyActiveRecordModel) }
      let(:model_b) { other_model_class.create(current_state: "x") }
      let(:items) { [item_for(model_a, "x", "y"), item_for(model_b, "x", "y")] }

      it "raises instead of silently resolving the wrong foreign key for some items" do
        expect { result }.to raise_error(ArgumentError, /same.*parent model class/)
      end
    end

    context "when items use different association names (but share a transition class)" do
      let(:model_a) { MyActiveRecordModel.create(current_state: "x") }
      let(:model_b) { MyActiveRecordModel.create(current_state: "x") }
      let(:items) do
        [
          item_for(model_a, "x", "y"),
          # :transitions is MyActiveRecordModel's own alias for the same association
          # (`alias_method :transitions, :my_active_record_model_transitions`) — a real,
          # callable method under a different name, so #build_transition still succeeds
          # and only the association_name *value* actually diverges.
          item_for(model_b, "x", "y", association_name: :transitions),
        ]
      end

      it "raises instead of silently resolving the wrong foreign key for some items" do
        expect { result }.to raise_error(ArgumentError, /same.*association name/)
      end
    end

    context "with no items" do
      let(:items) { [] }

      it "returns an empty, successful Result" do
        expect(result.successful).to eq([])
        expect(result.failed).to eq([])
        expect(result.success?).to be(true)
      end
    end
  end
end
