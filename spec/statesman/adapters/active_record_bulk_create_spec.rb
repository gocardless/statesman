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

  def adapter_for(model, transition_class: MyActiveRecordModelTransition, association_name: nil)
    described_class.new(transition_class, model, observer, { association_name: association_name }.compact)
  end

  # The payload shape .build_transitions takes: not yet built, carries from/to/metadata.
  def build_item_for(model, from, to, metadata: {}, transition_class: MyActiveRecordModelTransition,
                     association_name: nil)
    adapter = adapter_for(model, transition_class: transition_class, association_name: association_name)
    { object: model, adapter: adapter, from: from, to: to, metadata: metadata }
  end

  # The payload shape .bulk_create takes: already built (and, in BulkTransition's own
  # pipeline, already `before`-run) via .build_transitions. Constructed directly here
  # (not by calling .build_transitions) so .bulk_create's specs stay isolated from
  # .build_transitions's own correctness — `previous`/sort_key are derived the same way
  # .build_transitions itself derives them, generically via the real association so it
  # still works for an STI/custom-association item.
  def item_for(model, from, to, metadata: {}, transition_class: MyActiveRecordModelTransition,
               association_name: nil)
    adapter = adapter_for(model, transition_class: transition_class, association_name: association_name)
    previous = adapter.send(:transitions_for_parent).where(most_recent: true).first
    transition = adapter.build_transition(from, to, metadata)
    transition.assign_attributes(sort_key: previous ? previous.sort_key + 10 : 10, most_recent: true)
    { object: model, adapter: adapter, transition: transition, most_recent_id: previous&.id }
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

  describe ".build_transitions" do
    subject(:build_result) { described_class.build_transitions(items) }

    context "with parents that have no prior history" do
      let(:model_a) { MyActiveRecordModel.create(current_state: "x") }
      let(:model_b) { MyActiveRecordModel.create(current_state: "x") }
      let(:items) { [build_item_for(model_a, "x", "y"), build_item_for(model_b, "x", "y")] }

      it "returns a built, unsaved transition entry for every item, with no failures" do
        entries, failed = build_result

        expect(failed).to eq([])
        expect(entries).to contain_exactly(
          a_hash_including(object: model_a, transition: having_attributes(from_state: "x", to_state: "y",
                                                                          sort_key: 10, most_recent: true)),
          a_hash_including(object: model_b, transition: having_attributes(from_state: "x", to_state: "y",
                                                                          sort_key: 10, most_recent: true)),
        )
      end

      it "applies the given metadata" do
        entries, = described_class.build_transitions([build_item_for(model_a, "x", "y", metadata: { "k" => "v" })])
        expect(entries.first[:transition].metadata).to eq({ "k" => "v" })
      end

      it "does not persist anything" do
        build_result
        expect(MyActiveRecordModelTransition.count).to eq(0)
      end

      it "carries no most_recent_id, since there's no prior row to flip" do
        entries, = build_result
        expect(entries.map { |entry| entry[:most_recent_id] }).to eq([nil, nil])
      end
    end

    context "with a parent that already has history" do
      let(:model) { MyActiveRecordModel.create(current_state: "x") }
      let(:items) { [build_item_for(model, "x", "y")] }
      let(:previous) { adapter_for(model).create("w", "x") }

      before { previous }

      it "bases the new sort_key on the prior transition's" do
        entries, = build_result
        expect(entries.first[:transition].sort_key).to eq(20)
      end

      it "carries the prior transition's id as most_recent_id, for .bulk_create to flip" do
        entries, = build_result
        expect(entries.first[:most_recent_id]).to eq(previous.id)
      end
    end

    context "when a parent's current state no longer matches the requested from state (H2)" do
      let(:model_a) { MyActiveRecordModel.create(current_state: "x") }
      let(:model_b) { MyActiveRecordModel.create(current_state: "x") }
      let(:items) { [build_item_for(model_a, "x", "y"), build_item_for(model_b, "x", "y")] }

      before do
        # model_a has already moved on to "z" by the time .build_transitions is asked to
        # transition it from "x" — a stale read upstream of BulkTransition itself.
        adapter_for(model_a).create("x", "z")
      end

      it "reports the stale parent as a conflict and still builds the rest" do
        entries, failed = build_result

        expect(entries.map { |entry| entry[:object] }).to eq([model_b])
        expect(failed.map(&:object)).to eq([model_a])
      end

      it "tags the failure as a conflict, with a TransitionConflictError" do
        _, failed = build_result

        expect(failed.first.reason).to eq(:conflict)
        expect(failed.first.error).to be_a(Statesman::TransitionConflictError)
      end

      it "never touches a row for the stale parent" do
        build_result
        expect(model_a.reload.my_active_record_model_transitions.pluck(:to_state)).to eq(["z"])
      end
    end

    context "when building an item's transition raises" do
      let(:model_a) { MyActiveRecordModel.create(current_state: "x") }
      let(:model_b) { MyActiveRecordModel.create(current_state: "x") }
      let(:items) { [build_item_for(model_a, "x", "y"), build_item_for(model_b, "x", "y")] }
      let(:error) { StandardError.new("boom") }

      before { allow_any_instance_of(described_class).to receive(:build_transition).and_raise(error) }

      it "tags the failure as :build_transition, with the original error, for every item" do
        _, failed = build_result
        expect(failed.map(&:object)).to contain_exactly(model_a, model_b)
        expect(failed.map(&:reason).uniq).to eq([:build_transition])
        expect(failed.map(&:error).uniq).to eq([error])
      end
    end

    context "when items use different transition classes" do
      let(:model) { MyActiveRecordModel.create(current_state: "x") }
      let(:sti_model) { StiActiveRecordModel.create }
      let(:items) do
        [
          build_item_for(model, "x", "y"),
          build_item_for(sti_model, "x", "y", transition_class: StiAActiveRecordModelTransition,
                                              association_name: :sti_a_active_record_model_transitions),
        ]
      end

      it "raises instead of silently reading/writing some items against the wrong table" do
        expect { build_result }.to raise_error(ArgumentError, /same.*transition class/)
      end
    end

    context "when items use different parent model classes (but share a transition class)" do
      let(:model_a) { MyActiveRecordModel.create(current_state: "x") }
      let(:other_model_class) { Class.new(MyActiveRecordModel) }
      let(:model_b) { other_model_class.create(current_state: "x") }
      let(:items) { [build_item_for(model_a, "x", "y"), build_item_for(model_b, "x", "y")] }

      it "raises instead of silently resolving the wrong foreign key for some items" do
        expect { build_result }.to raise_error(ArgumentError, /same.*parent model class/)
      end
    end

    context "when items use different association names (but share a transition class)" do
      let(:model_a) { MyActiveRecordModel.create(current_state: "x") }
      let(:model_b) { MyActiveRecordModel.create(current_state: "x") }
      let(:items) do
        [
          build_item_for(model_a, "x", "y"),
          build_item_for(model_b, "x", "y", association_name: :transitions),
        ]
      end

      it "raises instead of silently resolving the wrong foreign key for some items" do
        expect { build_result }.to raise_error(ArgumentError, /same.*association name/)
      end
    end

    context "with no items" do
      let(:items) { [] }

      it "returns an empty entries/failed pair" do
        entries, failed = build_result
        expect(entries).to eq([])
        expect(failed).to eq([])
      end
    end
  end

  describe ".bulk_create" do
    subject(:result) { described_class.bulk_create(items) }

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

      it "applies the metadata already assigned onto the built transition" do
        items.each { |item| item[:transition].assign_attributes(metadata: { "k" => "v" }) }
        result
        expect(model_a.reload.my_active_record_model_transitions.first.metadata).to eq({ "k" => "v" })
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

    context "when a parent is raced between .build_transitions's read and .bulk_create's flip/insert (H1)" do
      let(:model_a) { MyActiveRecordModel.create(current_state: "x") }
      let(:model_b) { MyActiveRecordModel.create(current_state: "x") }
      let(:items) do
        adapter_for(model_a).create("w", "x")
        built = [item_for(model_a, "x", "y"), item_for(model_b, "x", "y")]
        # A concurrent single transition lands for model_a right after the items above
        # captured their most_recent_id (standing in for .build_transitions's own
        # snapshot read), before .bulk_create's flip/recheck — exactly the race window
        # that recheck protects.
        adapter_for(model_a).create("x", "z")
        built
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
      let(:items) do
        built = [item_for(model, "x", "y")]
        adapter_for(model).create("x", "z")
        built
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
      #
      # attempt == 2: .bulk_create's own first read is #flip_and_partition's recheck on
      # write_chunk's first attempt (attempt 1); the retry (write_chunk attempt 2) is
      # this method's *second* call to #most_recent_rows_for — unlike the old single-
      # method design, there's no extra pre-read inside .bulk_create itself any more
      # (that moved to .build_transitions), so the retry's recheck is call #2, not #3.
      before do
        attempt = 0
        allow_any_instance_of(described_class::BulkCreate).to receive(:most_recent_rows_for).
          and_wrap_original do |original, parent_ids|
            attempt += 1
            rows = original.call(parent_ids)
            attempt == 2 ? rows.merge(model_a.id => { id: -1, sort_key: 999, to_state: "x" }) : rows
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
