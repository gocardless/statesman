require "spec_helper"
require 'pry'

describe Statesmin::TransitionHelper do
  let(:transition_class)  { Class.new { include Statesmin::TransitionHelper } }
  let(:state_machine) { double }
  let(:instance) do
    transition_class.new.tap do |instance|
      allow(instance).to receive(:state_machine).and_return(state_machine)
    end
  end

  context 'delegated methods' do
    context 'when no state_machine method is defined' do
      let(:unimplemented_instance) { transition_class.new }

      Statesmin::TransitionHelper::DELEGATED_METHODS.each do |method_name|
        describe "##{method_name}" do
          it 'raises a RuntimeError' do
            expect { unimplemented_instance.send(method_name) }.
              to raise_error(RuntimeError)
          end
        end
      end
    end

    context 'when a state_machine method is defined' do
      Statesmin::TransitionHelper::DELEGATED_METHODS.each do |method_name|
        describe "##{method_name}" do
          it 'calls that method on the state_machine' do
            expect(state_machine).to receive(method_name)
            instance.send(method_name)
          end
        end
      end
    end
  end

  shared_examples 'a transition method' do |method|
    context 'when no transition method is defined' do
      it 'raises a RuntimeError' do
        expect { instance.send(method, :next) }.to raise_error(RuntimeError)
      end
    end

    context 'when a transition method is defined' do
      let(:transition) { double }
      before do
        instance.define_singleton_method :transition, -> (_state, _) { nil }
        allow(instance).to receive(:transition).and_return(transition)
      end

      context 'when the next_state argument is a valid transition' do
        before do
          allow(state_machine).to receive(:can_transition_to?).and_return(true)
          allow(state_machine).to receive(:current_state).and_return('new')
        end

        it 'calls the transition method' do
          expect(instance).to receive(:transition)
          instance.send(method, :next)
        end

        it 'resets the @state_machine instance variable' do
          instance.instance_variable_set(:@state_machine, true)
          instance.send(method, :next)
          expect(instance.instance_variable_get(:@state_machine)).to be_nil
        end

        it 'returns the value of the transition method' do
          allow(instance).to receive(:transition).and_return(42)
          expect(instance.send(method, :next)).to eq(42)
        end
      end
    end
  end

  describe '#transition_to!' do
    it_behaves_like 'a transition method', :transition_to!

    context 'when a valid transition method is defined' do
      let(:transition) { double }
      before do
        instance.define_singleton_method :transition, -> (_state, _) { nil }
      end

      context 'and the next_state argument is not a valid transition' do
        before do
          allow(state_machine).to receive(:can_transition_to?).and_return(false)
          allow(state_machine).to receive(:current_state).and_return('new')
        end

        it 'raises a TransitionFailedError' do
          expect { instance.transition_to!(:next) }.
            to raise_error(Statesmin::TransitionFailedError)
        end
      end
    end

    context 'when a error raising transition method is defined' do
      let(:transition) { double }
      before do
        instance.define_singleton_method :transition, -> (_state, _) { raise }
      end

      context 'and the next_state argument is a valid' do
        before do
          allow(state_machine).to receive(:can_transition_to?).and_return(true)
          allow(state_machine).to receive(:current_state).and_return('new')
        end

        it 'raises an error' do
          expect { instance.transition_to!(:next) }.to raise_error
        end
      end
    end
  end

  describe '#transition_to' do
    it_behaves_like 'a transition method', :transition_to

    context 'when a valid transition method is defined' do
      let(:transition) { double }
      before do
        instance.define_singleton_method :transition, -> (_state, _) { nil }
      end

      context 'and the next_state argument is not a valid transition' do
        before do
          allow(state_machine).to receive(:can_transition_to?).and_return(false)
          allow(state_machine).to receive(:current_state).and_return('new')
        end

        it 'returns false' do
          expect(instance.transition_to(:next)).to eq(false)
        end
      end
    end

    context 'when a transition method raises a RuntimeError' do
      let(:transition) { double }
      before do
        instance.define_singleton_method :transition do |_state, _|
          raise RuntimeError
        end
      end

      context 'and the next_state argument is a valid' do
        before do
          allow(state_machine).to receive(:can_transition_to?).and_return(true)
          allow(state_machine).to receive(:current_state).and_return('new')
        end

        it 'raises a RuntimeError' do
          expect { instance.transition_to(:next) }.to raise_error(RuntimeError)
        end
      end
    end

    context 'when a transition method raises a TransitionFailedError' do
      let(:transition) { double }
      before do
        instance.define_singleton_method :transition do |_state, _|
          raise Statesmin::TransitionFailedError
        end
      end

      context 'and the next_state argument is a valid' do
        before do
          allow(state_machine).to receive(:can_transition_to?).and_return(true)
          allow(state_machine).to receive(:current_state).and_return('new')
        end

        it 'returns false' do
          expect(instance.transition_to(:next)).to eq(false)
        end
      end
    end
  end
end
