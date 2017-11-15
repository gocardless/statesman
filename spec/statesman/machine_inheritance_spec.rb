require "spec_helper"

describe Statesman::MachineInheritance do
  describe "state machine inheritance module" do
    let!(:parent_state_machine) { Class.new.include(Statesman::Machine) }
    let!(:child_state_machine) { Class.new.include(Statesman::Machine) }

    let(:initial_state) { "zeroth_state" }
    let(:other_states) { %w[first_state second_state third_state] }
    let(:all_states) { ([initial_state] + other_states) }

    before do
      parent_state_machine.state(initial_state, initial: true)
      other_states.each { |state| parent_state_machine.state state }

      child_state_machine.include(described_class)
    end

    context "enables state inheritance from the parent state machine" do
      context "for initial state" do
        it do
          expect(child_state_machine.initial_state).to be(nil)

          child_state_machine.inherit_initial_state_from parent_state_machine
          expect(child_state_machine.initial_state).to eql(initial_state)
        end
      end

      context "for other states" do
        it do
          expect(child_state_machine.states).to eql([])

          child_state_machine.inherit_states_from parent_state_machine
          expect(child_state_machine.states).to eql(all_states)
        end
      end

      context "but does not duplicate already existing states" do
        before { child_state_machine.state :first_state }

        it do
          child_state_machine.inherit_states_from parent_state_machine
          expect(child_state_machine.states.count("first_state")).to be(1)
        end
      end
    end

    context "enables transition inheritance from the parent state machine" do
      before do
        child_state_machine.inherit_states_from parent_state_machine
        parent_state_machine.transition from: initial_state, to: other_states
      end

      it do
        expect(child_state_machine.successors).to eql({})

        child_state_machine.inherit_transitions_from parent_state_machine
        expect(child_state_machine.successors).
          to eql(initial_state => other_states)
      end
    end

    context "enables callback inheritance from the parent_state_machine" do
      before do
        child_state_machine.inherit_states_from parent_state_machine
        parent_state_machine.transition from: initial_state, to: other_states

        child_state_machine_callbacks = child_state_machine.callbacks
        expect(child_state_machine_callbacks[:before]).to eql([])
        expect(child_state_machine_callbacks[:after]).to eql([])
        expect(child_state_machine_callbacks[:guards]).to eql([])
      end

      context "for 'guards'" do
        before do
          parent_state_machine.guard_transition { true }
        end

        it do
          child_state_machine.inherit_callbacks_from parent_state_machine
          expect(child_state_machine.callbacks[:guards].length).to be(1)
        end
      end

      context "for 'before' callbacks" do
        before do
          parent_state_machine.before_transition { true }
        end

        it do
          child_state_machine.inherit_callbacks_from parent_state_machine
          expect(child_state_machine.callbacks[:before].length).to be(1)
        end
      end

      context "for 'after' callbacks" do
        before do
          parent_state_machine.after_transition { true }
        end

        it do
          child_state_machine.inherit_callbacks_from parent_state_machine
          expect(child_state_machine.callbacks[:after].length).to be(1)
        end
      end
    end
  end
end
