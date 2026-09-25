# frozen_string_literal: true

# NOTE on verification strategy: the memory adapter's history is scoped to a single
# Machine instance's lifetime (Adapters::Memory#initialize always starts `@history =
# []`), not to the parent object — this is pre-existing and unrelated to bulk
# transitions (a fresh `machine_class.new(model)` never sees a transition written by a
# *different* instance for the same model, with or without bulk_transition_to! — this
# was confirmed on unmodified code too: `klass.new(m).transition_to!(:y)` followed by a
# fresh `klass.new(m).current_state` returns "x", not "y"). bulk_transition_to! itself
# only ever builds one machine per object per call and uses it consistently for that call,
# so this doesn't affect correctness — but it does mean these specs can't verify
# results by re-instantiating a fresh machine afterward. Instead they rely on
# `result.transitioned`/`result.failed` (built during the call itself), a real
# `after_transition` callback to capture written transitions where deeper properties
# matter, and `allow_any_instance_of` (already used elsewhere in this codebase, e.g.
# machine_spec.rb) on the rare occasion a test needs objects starting from different
# states within one call.
describe Statesman::BulkTransition do
  let(:machine_class) do
    Class.new do
      include Statesman::Machine

      def self.name
        "MyBulkStateMachine"
      end

      state :x, initial: true
      state :y
      state :z
      transition from: :x, to: :y
      transition from: :x, to: :z
      transition from: :y, to: :z
    end
  end

  let(:model_class) { Class.new { attr_accessor :current_state } }
  let(:captured) { {} }

  def build_objects(count)
    Array.new(count) { model_class.new }
  end

  # Registers a real Statesman `after` callback to capture the transition actually
  # written for each object, keyed by object. Does not fire under skip_callbacks.
  def capture_transitions!
    store = captured
    machine_class.after_transition { |object, transition| store[object] = transition }
  end

  describe "end-to-end on the memory adapter" do
    subject(:result) { machine_class.bulk_transition_to!(objects, :y) }

    let(:objects) { build_objects(3) }

    before { capture_transitions! }

    it "transitions every object and reports no failures" do
      expect(result.transitioned).to match_array(objects)
      expect(result.failed).to eq([])
      expect(result.success?).to be(true)
    end

    it "actually writes each object's transition to state y" do
      result
      objects.each { |object| expect(captured[object].to_state).to eq("y") }
    end

    it "applies the given metadata to every transition in the batch" do
      machine_class.bulk_transition_to!(objects, :y, metadata: { "batch_id" => 42 })
      objects.each { |object| expect(captured[object].metadata).to eq({ "batch_id" => 42 }) }
    end

    context "with a mixed batch (some succeed, one is guarded, one has a bad edge)" do
      let(:good_object) { model_class.new }
      let(:guarded_object) { model_class.new }
      let(:invalid_object) { model_class.new }
      let(:objects) { [good_object, guarded_object, invalid_object] }

      before do
        machine_class.guard_transition(from: :x, to: :y) { |object, *| object != guarded_object }

        # invalid_object needs a *different* starting state than the other two so that
        # :y is not a declared successor of it; see the file-level NOTE on why this is
        # stubbed rather than set up via a real prior transition.
        allow_any_instance_of(machine_class).to receive(:current_state) do |instance|
          instance.object == invalid_object ? "z" : "x"
        end
      end

      it "partitions transitioned vs failed correctly" do
        result = machine_class.bulk_transition_to!(objects, :y)

        expect(result.transitioned).to eq([good_object])
        expect(result.failed).to contain_exactly(
          having_attributes(object: guarded_object, reason: :guard),
          having_attributes(object: invalid_object, reason: :invalid_current_state),
        )
      end
    end
  end

  describe "equivalence with a loop of #transition_to!" do
    before { capture_transitions! }

    it "produces the same final transition shape" do
      looped = build_objects(2)
      bulked = build_objects(2)

      looped.each { |object| machine_class.new(object).transition_to!(:y, { "k" => "v" }) }
      machine_class.bulk_transition_to!(bulked, :y, metadata: { "k" => "v" })

      looped.zip(bulked).each do |looped_object, bulked_object|
        looped_transition = captured[looped_object]
        bulked_transition = captured[bulked_object]

        expect(bulked_transition).to have_attributes(
          from_state: looped_transition.from_state,
          to_state: looped_transition.to_state,
          sort_key: looped_transition.sort_key,
          metadata: looped_transition.metadata,
        )
      end
    end
  end

  describe "successor validation" do
    subject(:result) do
      machine_class.bulk_transition_to!([object], :x, skip_guards: true, skip_callbacks: true)
    end

    let(:object) { model_class.new }

    it "is enforced even with skip_guards and skip_callbacks set" do
      # x has no self-edge declared, so this must fail structurally regardless of the
      # skips.
      expect(result.transitioned).to eq([])
      expect(result.failed.first.reason).to eq(:invalid_current_state)
    end
  end

  describe "on_failure: :raise" do
    let(:objects) { build_objects(2) }

    before do
      capture_transitions!
      machine_class.guard_transition(from: :x, to: :y) { false }
    end

    it "raises the underlying error instead of collecting a failure, aborting the batch" do
      expect { machine_class.bulk_transition_to!(objects, :y, on_failure: :raise) }.
        to raise_error(Statesman::GuardFailedError)

      expect(captured).to be_empty
    end
  end

  describe "skip_guards" do
    let(:objects) { build_objects(2) }

    before { machine_class.guard_transition(from: :x, to: :y) { false } }

    it "suppresses guard evaluation, so the transition succeeds" do
      result = machine_class.bulk_transition_to!(objects, :y, skip_guards: true)

      expect(result.transitioned).to match_array(objects)
      expect(result.success?).to be(true)
    end
  end

  describe "skip_callbacks" do
    let(:objects) { build_objects(2) }
    let(:calls) { [] }

    before do
      recorder = calls
      machine_class.before_transition { |*args| recorder << [:before, args] }
      machine_class.after_transition { |*args| recorder << [:after, args] }
      machine_class.after_transition(after_commit: true) { |*args| recorder << [:after_commit, args] }
    end

    it "fires no before/after/after_commit callbacks, but still persists the transition" do
      result = machine_class.bulk_transition_to!(objects, :y, skip_callbacks: true)

      expect(calls).to eq([])
      expect(result.transitioned).to match_array(objects)
    end
  end

  describe "a batch spanning several from states" do
    let(:x_object) { model_class.new }
    let(:y_object) { model_class.new }

    before do
      # See the file-level NOTE: stubbing simulates y_object already being at :y,
      # exactly what a real persisted adapter would give for free.
      allow_any_instance_of(machine_class).to receive(:current_state) do |instance|
        instance.object == y_object ? "y" : "x"
      end
      machine_class.guard_transition(from: :y, to: :z) { false }
    end

    it "buckets by from state and validates/guards each bucket independently" do
      result = machine_class.bulk_transition_to!([x_object, y_object], :z)

      expect(result.transitioned).to eq([x_object])
      expect(result.failed.map(&:object)).to eq([y_object])
      expect(result.failed.first.reason).to eq(:guard)
    end
  end

  describe "batch_size chunking" do
    let(:objects) { build_objects(5) }

    it "processes every object across multiple chunks" do
      result = machine_class.bulk_transition_to!(objects, :y, batch_size: 2)

      expect(result.transitioned).to match_array(objects)
      expect(result.success?).to be(true)
    end
  end
end
