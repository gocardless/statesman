require "spec_helper"

# All adpators must define seven methods:
#   initialize:       Accepts a transition class, parent model and state_attr.
#   transition_class: Returns the transition class object passed to initialize.
#   parent_model:     Returns the model class object passed to initialize.
#   state_attr:       Returns the state attribute to set on the parent.
#   create:           Accepts to_state, before callbacks, after callbacks and
#                     optional metadata. Creates a new transition class
#                     instance and saves metadata to it.
#   history:          Returns the full transition history
#   last:             Returns the latest transition history item
#
# NOTE This line cannot reasonably be shortened.
shared_examples_for "an adapter" do |adapter_class, transition_class, options = {}|
  let(:observer) { double(Statesman::Machine, execute: nil) }
  let(:adapter) do
    adapter_class.new(transition_class,
                      model, observer, options)
  end

  describe "#initialize" do
    subject { adapter }

    its(:transition_class) { is_expected.to be(transition_class) }
    its(:parent_model) { is_expected.to be(model) }
    its(:history) { is_expected.to eq([]) }
  end

  describe "#create" do
    subject { -> { create } }

    let(:from) { :x }
    let(:to) { :y }
    let(:there) { :z }
    let(:create) { adapter.create(from, to) }

    it { is_expected.to change(adapter.history, :count).by(1) }

    context "the new transition" do
      subject(:instance) { create }

      it { is_expected.to be_a(transition_class) }

      it "has the initial state" do
        expect(instance.to_state.to_sym).to eq(to)
      end

      context "with no previous transition" do
        its(:sort_key) { is_expected.to be(10) }
      end

      context "with a previous transition" do
        before { adapter.create(from, to) }

        its(:sort_key) { is_expected.to be(20) }
      end
    end

    context "with before callbacks" do
      it "is called before the state transition" do
        expect(observer).to receive(:execute).
          with(:before, anything, anything, anything) {
            expect(adapter.history.length).to eq(0)
          }.once
        adapter.create(from, to)
        expect(adapter.history.length).to eq(1)
      end
    end

    context "with after callbacks" do
      it "is called after the state transition" do
        expect(observer).to receive(:execute).
          with(:after, anything, anything, anything) { |_, _, _, transition|
            expect(adapter.last).to eq(transition)
          }.once
        adapter.create(from, to)
      end

      it "exposes the new transition for subsequent transitions" do
        adapter.create(from, to)

        expect(observer).to receive(:execute).
          with(:after, anything, anything, anything) { |_, _, _, transition|
            expect(adapter.last).to eq(transition)
          }.once
        adapter.create(to, there)
      end
    end

    context "with metadata" do
      subject { adapter.create(from, to, metadata) }

      let(:metadata) { { "some" => "hash" } }

      its(:metadata) { is_expected.to eq(metadata) }
    end
  end

  describe "#history" do
    subject { adapter.history }

    it { is_expected.to eq([]) }

    context "with transitions" do
      let!(:transition) { adapter.create(:x, :y) }

      it { is_expected.to eq([transition]) }

      context "sorting" do
        subject { adapter.history }

        let!(:transition2) { adapter.create(:x, :y) }

        it { is_expected.to eq(adapter.history.sort_by(&:sort_key)) }
      end
    end
  end

  describe "#last" do
    subject { adapter.last }

    before { adapter.create(:x, :y) }

    before { adapter.create(:y, :z) }

    it { is_expected.to be_a(transition_class) }
    specify { expect(adapter.last.to_state.to_sym).to eq(:z) }
    specify do
      expect(adapter.last(force_reload: true).to_state.to_sym).to eq(:z)
    end
  end
end
