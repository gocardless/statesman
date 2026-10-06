# frozen_string_literal: true

require "statesman/exceptions"

describe Statesman::Adapters::ActiveRecord, :active_record do
  before do
    prepare_model_table
    prepare_transitions_table

    prepare_sti_model_table
    prepare_sti_transitions_table

    prepare_validated_model_table
    prepare_validated_transitions_table

    Statesman.configure do
      # described_class isn't reachable here — Statesman.configure instance_evals this
      # block against a Statesman::Config instance, not the example group.
      storage_adapter(Statesman::Adapters::ActiveRecord) # rubocop:disable RSpec/DescribedClass
    end
  end

  after { Statesman.configure { storage_adapter(Statesman::Adapters::Memory) } }

  let(:machine_class) do
    Class.new do
      include Statesman::Machine

      def self.name
        "MyArBulkStateMachine"
      end

      state :x, initial: true
      state :y
      transition from: :x, to: :y
    end
  end

  def adapter_for(model, transition_class: MyActiveRecordModelTransition, association_name: nil)
    machine_class.new(model, { transition_class: transition_class, association_name: association_name }.compact).
      storage_adapter
  end

  # The payload shape .bulk_create takes: object/adapter/metadata, not yet built —
  # building, before/after/after_commit dispatch, and persisting are all .bulk_create's
  # own job now (see Adapters::ActiveRecord::BulkCreate).
  def item_for(model, metadata: {}, transition_class: MyActiveRecordModelTransition, association_name: nil)
    { object: model, adapter: adapter_for(model, transition_class: transition_class,
                                                 association_name: association_name), metadata: metadata }
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

  # Unit-level SQL mechanics (sort_key batching, conflicts, races, cached-state,
  # uniform-adapter checks) — drives .bulk_create directly. End-to-end equivalence with
  # a loop of #transition_to!, and before/after/after_commit's full transactional
  # behaviour (including per-item after isolation and after_commit timing), are covered
  # in spec/statesman/bulk_transition_active_record_spec.rb, through the real
  # Machine/BulkTransition/Adapters::ActiveRecord stack together.
  describe ".bulk_create" do
    subject(:result) { described_class.bulk_create(items, from: "x", to: "y") }

    context "with parents that have no prior history" do
      let(:model_a) { MyActiveRecordModel.create(current_state: "x") }
      let(:model_b) { MyActiveRecordModel.create(current_state: "x") }
      let(:items) { [item_for(model_a), item_for(model_b)] }

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
        described_class.bulk_create([item_for(model_a, metadata: { "k" => "v" })], from: "x", to: "y")
        expect(model_a.reload.my_active_record_model_transitions.first.metadata).to eq({ "k" => "v" })
      end
    end

    context "with a parent that already has history" do
      let(:model) { MyActiveRecordModel.create(current_state: "x") }
      let(:items) { [item_for(model)] }

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
      let(:items) { [item_for(model_a), item_for(model_b)] }

      before do
        # model_a has already moved on to "z" by the time .bulk_create is asked to
        # transition it from "x" — a stale read upstream of BulkTransition itself.
        adapter_for(model_a).create("x", "z")
      end

      it "reports the stale parent as a conflict and still transitions the rest" do
        expect(result.successful).to eq([model_b])
        expect(result.failed.map(&:object)).to eq([model_a])
      end

      it "tags the failure as a conflict, with a TransitionConflictError" do
        expect(result.failed.first.reason).to eq(:conflict)
        expect(result.failed.first.error).to be_a(Statesman::TransitionConflictError)
      end

      it "never touches a row for the stale parent" do
        result
        expect(model_a.reload.my_active_record_model_transitions.pluck(:to_state)).to eq(["z"])
      end
    end

    context "when building an item's transition raises" do
      let(:model_a) { MyActiveRecordModel.create(current_state: "x") }
      let(:model_b) { MyActiveRecordModel.create(current_state: "x") }
      let(:items) { [item_for(model_a), item_for(model_b)] }
      let(:error) { StandardError.new("boom") }

      before { allow_any_instance_of(described_class).to receive(:build_transition).and_raise(error) }

      it "tags the failure as :build_transition, with the original error, for every item" do
        expect(result.failed.map(&:object)).to contain_exactly(model_a, model_b)
        expect(result.failed.map(&:reason).uniq).to eq([:build_transition])
        expect(result.failed.map(&:error).uniq).to eq([error])
      end
    end

    context "when a parent is raced between the build phase's read and the flip/insert (H1)" do
      let(:model_a) { MyActiveRecordModel.create(current_state: "x") }
      let(:model_b) { MyActiveRecordModel.create(current_state: "x") }
      let(:items) { [item_for(model_a), item_for(model_b)] }

      before do
        adapter_for(model_a).create("w", "x")

        raced = false
        allow_any_instance_of(described_class::BulkCreate).to receive(:most_recent_rows_for).
          and_wrap_original do |original, *args|
            rows = original.call(*args)
            unless raced
              raced = true
              # A concurrent single transition lands for model_a right after the build
              # phase's own snapshot read, before the write phase's flip/recheck —
              # exactly the race window that recheck protects.
              adapter_for(model_a).create("x", "z")
            end
            rows
          end
      end

      it "drops only the raced parent as a conflict; the rest commit" do
        expect(result.successful).to eq([model_b])
        expect(result.failed.map(&:object)).to eq([model_a])
      end

      it "tags the race as a conflict, with a TransitionConflictError" do
        expect(result.failed.first.reason).to eq(:conflict)
        expect(result.failed.first.error).to be_a(Statesman::TransitionConflictError)
      end

      it "leaves model_a's history exactly as the racer wrote it, untouched by our attempt" do
        result
        expect(model_a.reload.my_active_record_model_transitions.order(:sort_key).map(&:to_state)).to eq(%w[x z])
      end

      context "with on_failure: :raise" do
        subject(:result) { described_class.bulk_create(items, from: "x", to: "y", on_failure: :raise) }

        it "raises instead of collecting the failure, but still leaves model_b's transition " \
           "committed (the chunk had already committed by the time this is checked)" do
          expect { result }.to raise_error(Statesman::TransitionConflictError)
          expect(model_b.reload.my_active_record_model_transitions.pluck(:to_state)).to eq(["y"])
        end
      end
    end

    context "when a brand-new parent is raced between the snapshot read and the insert" do
      let(:model) { MyActiveRecordModel.create(current_state: "x") }
      let(:items) { [item_for(model)] }

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
      let(:items) { [item_for(model_a), item_for(model_b)] }

      # A genuinely independent concurrent writer can't be simulated deterministically on
      # a single shared connection: a "racer" call nested inside our own open transaction
      # (the only way to reach this code from a single-threaded test) gets rolled back
      # *with* us when the retry's rollback happens, since savepoints aren't independent
      # of their parent transaction — so it wouldn't still be there for the retry to find.
      # Instead, this drives the same two observable events a real race would cause: (1)
      # insert_all! raises RecordNotUnique once, (2) the *retry's own* recheck finds the
      # raced parent — exactly what a real race landing in that window would produce.
      #
      # attempt == 3: call 1 is the build phase's own snapshot read; call 2 is
      # #flip_and_partition's recheck on write_chunk's first attempt; the retry
      # (write_chunk attempt 2) is call 3.
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

    describe "model_validations (WU4: save! fallback for transition models with validations/callbacks)" do
      context "with a plain transition model (no validations, only framework callback noise)" do
        let(:model) { MyActiveRecordModel.create(current_state: "x") }
        let(:items) { [item_for(model)] }

        it "still uses the insert_all! fast path, unaffected by belongs_to's own autosave callback" do
          expect_any_instance_of(described_class::BulkCreate).to receive(:insert_survivors!).and_call_original
          expect_any_instance_of(described_class::BulkCreate).to_not receive(:save_survivors!)
          result
        end
      end

      context "with a transition model whose only 'validation' is a Rails-injected " \
              "required-belongs_to presence check (bug: :auto used to always pick the slow path here)" do
        let(:model) { MyActiveRecordModel.create(current_state: "x") }
        let(:items) do
          [item_for(model, transition_class: RequiredAssociationActiveRecordModelTransition)]
        end

        it "still uses the fast insert_all! path, not save_survivors!" do
          expect_any_instance_of(described_class::BulkCreate).to receive(:insert_survivors!).and_call_original
          expect_any_instance_of(described_class::BulkCreate).to_not receive(:save_survivors!)
          result
        end

        it "persists successfully" do
          expect(result.successful).to eq([model])
          expect(result.failed).to eq([])
        end
      end

      context "with a transition model that has a real validation and create callback" do
        let(:model) { ValidatedActiveRecordModel.create(current_state: "x") }

        def validated_item_for(model: self.model, metadata: {})
          item_for(model, metadata: metadata, transition_class: ValidatedActiveRecordModelTransition)
        end

        context "on the success path" do
          let(:items) { [validated_item_for] }

          it "uses save_survivors! (the fallback), not insert_all!" do
            expect_any_instance_of(described_class::BulkCreate).to receive(:save_survivors!).and_call_original
            expect_any_instance_of(described_class::BulkCreate).to_not receive(:insert_survivors!)
            result
          end

          it "persists successfully, running the model's own validations/callbacks" do
            expect(result.successful).to eq([model])
            expect(result.failed).to eq([])
            expect(model.reload.validated_active_record_model_transitions.pluck(:to_state)).to eq(["y"])
          end

          it "round-trips metadata correctly, same as the fast path" do
            item = validated_item_for(metadata: { "some" => "hash" })
            described_class.bulk_create([item], from: "x", to: "y")
            expect(model.reload.validated_active_record_model_transitions.first.metadata).
              to eq({ "some" => "hash" })
          end
        end

        context "when a validation fails on one item in the chunk" do
          let(:other_model) { ValidatedActiveRecordModel.create(current_state: "x") }
          let(:items) { [validated_item_for, validated_item_for(model: other_model)] }

          # Mutating `to_state` to blank in a `before` callback is the new-architecture
          # equivalent of the old approach (building the item's transition early and
          # setting a blank `to_state` on it directly) — items no longer carry a
          # pre-built transition of their own, `to_state` is shared for the whole batch,
          # so a per-item invalid value has to be injected via the one hook that still
          # sees each item's own transition before it's persisted.
          before do
            machine_class.before_transition do |object, transition|
              transition.to_state = "" if object == other_model
            end
          end

          it "raises ActiveRecord::RecordInvalid instead of silently dropping the other item's work" do
            expect { result }.to raise_error(ActiveRecord::RecordInvalid)
          end

          it "rolls back the whole chunk: no row survives for any item in it" do
            suppress(ActiveRecord::RecordInvalid) { result }

            expect(model.reload.validated_active_record_model_transitions).to be_empty
            expect(other_model.reload.validated_active_record_model_transitions).to be_empty
          end
        end

        context "when a before_create callback halts on one item in the chunk" do
          let(:other_model) { ValidatedActiveRecordModel.create(current_state: "x") }
          let(:items) { [validated_item_for, validated_item_for(model: other_model)] }

          before do
            machine_class.before_transition do |object, transition|
              transition.abort_on_create = true if object == other_model
            end
          end

          it "raises ActiveRecord::RecordNotSaved instead of silently dropping the other item's work" do
            expect { result }.to raise_error(ActiveRecord::RecordNotSaved)
          end

          it "rolls back the whole chunk: no row survives for any item in it" do
            suppress(ActiveRecord::RecordNotSaved) { result }

            expect(model.reload.validated_active_record_model_transitions).to be_empty
            expect(other_model.reload.validated_active_record_model_transitions).to be_empty
          end
        end

        context "when save! itself hits a transient RecordNotUnique mid-loop" do
          let(:other_model) { ValidatedActiveRecordModel.create(current_state: "x") }
          let(:items) { [validated_item_for, validated_item_for(model: other_model)] }

          before do
            attempt = 0
            allow_any_instance_of(described_class::BulkCreate).to receive(:most_recent_rows_for).
              and_wrap_original do |original, parent_ids|
                attempt += 1
                rows = original.call(parent_ids)
                attempt == 3 ? rows.merge(model.id => { id: -1, sort_key: 999, to_state: "x" }) : rows
              end

            raised = false
            allow_any_instance_of(described_class::BulkCreate).to receive(:save_survivors!).
              and_wrap_original do |original, *args|
                unless raised
                  raised = true
                  raise ActiveRecord::RecordNotUnique, "simulated race"
                end
                original.call(*args)
              end
          end

          it "retries via write_chunk's existing rescue, excluding whoever the retry finds raced" do
            expect(result.successful).to eq([other_model])
            expect(result.failed.map(&:object)).to eq([model])
            expect(result.failed.first.reason).to eq(:conflict)
          end
        end
      end

      context "with an STI transition model that inherits a real validation" do
        let(:sti_model) { StiActiveRecordModel.create }
        let(:items) do
          [item_for(sti_model, transition_class: StiAActiveRecordModelTransition,
                               association_name: :sti_a_active_record_model_transitions)]
        end

        it "uses save_survivors!, same as any other transition class with a real validation" do
          expect_any_instance_of(described_class::BulkCreate).to receive(:save_survivors!).and_call_original
          expect_any_instance_of(described_class::BulkCreate).to_not receive(:insert_survivors!)
          result
        end

        it "persists the STI type column correctly on the fallback path" do
          result
          transition = sti_model.reload.sti_a_active_record_model_transitions.first
          expect(transition).to be_a(StiAActiveRecordModelTransition)
          expect(transition.type).to eq("StiAActiveRecordModelTransition")
        end
      end

      context "with model_validations: :skip" do
        subject(:result) { described_class.bulk_create(items, from: "x", to: "", model_validations: :skip) }

        let(:model) { ValidatedActiveRecordModel.create(current_state: "x") }
        # Blank to_state would fail ValidatedActiveRecordModelTransition's `validates
        # :to_state, presence: true` under the save! fallback — proving :skip really
        # bypasses it, same tradeoff this whole option exists to let a caller opt into.
        let(:items) { [item_for(model, transition_class: ValidatedActiveRecordModelTransition)] }

        it "forces the fast insert_all! path even though the model has real validations" do
          expect_any_instance_of(described_class::BulkCreate).to receive(:insert_survivors!).and_call_original
          expect_any_instance_of(described_class::BulkCreate).to_not receive(:save_survivors!)
          expect(result.successful).to eq([model])
        end
      end

      context "with model_validations: :enforce" do
        subject(:result) { described_class.bulk_create(items, from: "x", to: "y", model_validations: :enforce) }

        let(:model) { MyActiveRecordModel.create(current_state: "x") }
        let(:items) { [item_for(model)] }

        it "forces the save! fallback even though the model has no real validations/callbacks" do
          expect_any_instance_of(described_class::BulkCreate).to receive(:save_survivors!).and_call_original
          expect_any_instance_of(described_class::BulkCreate).to_not receive(:insert_survivors!)
          expect(result.successful).to eq([model])
        end
      end
    end

    context "when items use different transition classes" do
      let(:model) { MyActiveRecordModel.create(current_state: "x") }
      let(:sti_model) { StiActiveRecordModel.create }
      let(:items) do
        [
          item_for(model),
          item_for(sti_model, transition_class: StiAActiveRecordModelTransition,
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
      let(:items) { [item_for(model_a), item_for(model_b)] }

      it "raises instead of silently resolving the wrong foreign key for some items" do
        expect { result }.to raise_error(ArgumentError, /same.*parent model class/)
      end
    end

    context "when items use different association names (but share a transition class)" do
      let(:model_a) { MyActiveRecordModel.create(current_state: "x") }
      let(:model_b) { MyActiveRecordModel.create(current_state: "x") }
      let(:items) do
        [
          item_for(model_a),
          # :transitions is MyActiveRecordModel's own alias for the same association
          # (`alias_method :transitions, :my_active_record_model_transitions`) — a real,
          # callable method under a different name, so #build_transition still succeeds
          # and only the association_name *value* actually diverges.
          item_for(model_b, association_name: :transitions),
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

    # Basic dispatch wiring — see spec/statesman/bulk_transition_active_record_spec.rb
    # for the full transactional-behaviour coverage (per-item after isolation,
    # after_commit timing).
    describe "before/after/after_commit dispatch" do
      let(:model) { MyActiveRecordModel.create(current_state: "x") }
      let(:items) { [item_for(model)] }
      let(:calls) { [] }

      before do
        recorder = calls
        machine_class.before_transition { |object, _transition| recorder << [:before, object] }
        machine_class.after_transition { |object, _transition| recorder << [:after, object] }
        machine_class.after_transition(after_commit: true) { |object, _transition| recorder << [:after_commit, object] }
      end

      # after_commit is registered during the chunk's own write (decoupled from
      # `after` — see BulkCreate's docs), so for a single, unwrapped call it fires
      # before `after`, which only runs once that write has already committed.
      it "runs before, then persists (registering after_commit), then after" do
        result
        expect(calls).to eq([[:before, model], [:after_commit, model], [:after, model]])
      end

      it "respects skip_before_callbacks/skip_after_callbacks/skip_after_commit_callbacks" do
        described_class.bulk_create(items, from: "x", to: "y", skip_before_callbacks: true,
                                           skip_after_callbacks: true, skip_after_commit_callbacks: true)
        expect(calls).to eq([])
      end
    end
  end
end
