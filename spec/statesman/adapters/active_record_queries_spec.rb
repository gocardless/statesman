require "spec_helper"

describe Statesman::Adapters::ActiveRecordQueries, active_record: true do
  before do
    prepare_model_table
    prepare_transitions_table
    prepare_other_model_table
    prepare_other_transitions_table

    Statesman.configure { storage_adapter(Statesman::Adapters::ActiveRecord) }

    MyActiveRecordModel.send(:include, Statesman::Adapters::ActiveRecordQueries)
    MyActiveRecordModel.class_eval do
      def self.transition_class
        MyActiveRecordModelTransition
      end

      def self.initial_state
        :initial
      end
    end

    OtherActiveRecordModel.send(:include,
                                Statesman::Adapters::ActiveRecordQueries)
    OtherActiveRecordModel.class_eval do
      def self.transition_class
        OtherActiveRecordModelTransition
      end

      def self.initial_state
        :initial
      end
    end

    MyActiveRecordModel.send(:has_one, :other_active_record_model)
    OtherActiveRecordModel.send(:belongs_to, :my_active_record_model)
  end

  after { Statesman.configure { storage_adapter(Statesman::Adapters::Memory) } }

  let!(:model) do
    model = MyActiveRecordModel.create
    model.state_machine.transition_to(:succeeded)
    model
  end

  let!(:other_model) do
    model = MyActiveRecordModel.create
    model.state_machine.transition_to(:failed)
    model
  end

  let!(:initial_state_model) { MyActiveRecordModel.create }

  let!(:returned_to_initial_model) do
    model = MyActiveRecordModel.create
    model.state_machine.transition_to(:failed)
    model.state_machine.transition_to(:initial)
    model
  end

  describe ".in_state" do
    context "given a single state" do
      subject { MyActiveRecordModel.in_state(:succeeded) }

      it { is_expected.to include model }
      it { is_expected.to_not include other_model }
    end

    context "given multiple states" do
      subject { MyActiveRecordModel.in_state(:succeeded, :failed) }

      it { is_expected.to include model }
      it { is_expected.to include other_model }
    end

    context "given the initial state" do
      subject { MyActiveRecordModel.in_state(:initial) }

      it { is_expected.to include initial_state_model }
      it { is_expected.to include returned_to_initial_model }
    end

    context "given an array of states" do
      subject { MyActiveRecordModel.in_state(%i[succeeded failed]) }

      it { is_expected.to include model }
      it { is_expected.to include other_model }
    end

    context "merging two queries" do
      subject do
        MyActiveRecordModel.in_state(:succeeded).
          joins(:other_active_record_model).
          merge(OtherActiveRecordModel.in_state(:initial))
      end

      it { is_expected.to be_empty }
    end
  end

  describe ".not_in_state" do
    context "given a single state" do
      subject { MyActiveRecordModel.not_in_state(:failed) }

      it { is_expected.to include model }
      it { is_expected.to_not include other_model }
    end

    context "given multiple states" do
      subject(:not_in_state) { MyActiveRecordModel.not_in_state(:succeeded, :failed) }

      it do
        expect(not_in_state).to match_array([initial_state_model,
                                             returned_to_initial_model])
      end
    end

    context "given an array of states" do
      subject(:not_in_state) { MyActiveRecordModel.not_in_state(%i[succeeded failed]) }

      it do
        expect(not_in_state).to match_array([initial_state_model,
                                             returned_to_initial_model])
      end
    end
  end

  context "with a custom name for the transition association" do
    before do
      # Switch to using OtherActiveRecordModelTransition, so the existing
      # relation with MyActiveRecordModelTransition doesn't interfere with
      # this spec.
      MyActiveRecordModel.send(:has_many,
                               :custom_name,
                               class_name: "OtherActiveRecordModelTransition")

      MyActiveRecordModel.class_eval do
        def self.transition_class
          OtherActiveRecordModelTransition
        end
      end
    end

    describe ".in_state" do
      subject(:query) { MyActiveRecordModel.in_state(:succeeded) }

      specify { expect { query }.to_not raise_error }
    end
  end

  context "with no association with the transition class" do
    before do
      class UnknownModelTransition < OtherActiveRecordModelTransition; end

      MyActiveRecordModel.class_eval do
        def self.transition_class
          UnknownModelTransition
        end
      end
    end

    describe ".in_state" do
      subject(:query) { MyActiveRecordModel.in_state(:succeeded) }

      it "raises a helpful error" do
        expect { query }.to raise_error(Statesman::MissingTransitionAssociation)
      end
    end
  end

  context "after_commit transactional integrity" do
    before do
      MyStateMachine.class_eval do
        cattr_accessor(:after_commit_callback_executed) { false }

        after_transition(from: :initial, to: :succeeded, after_commit: true) do
          # This leaks state in a testable way if transactional integrity is broken.
          MyStateMachine.after_commit_callback_executed = true
        end
      end
    end

    after do
      MyStateMachine.class_eval do
        callbacks[:after_commit] = []
      end
    end

    let!(:model) do
      MyActiveRecordModel.create
    end

    # rubocop:disable RSpec/ExampleLength
    it do
      expect do
        ActiveRecord::Base.transaction do
          model.state_machine.transition_to!(:succeeded)
          raise ActiveRecord::Rollback
        end
      end.to_not change(MyStateMachine, :after_commit_callback_executed)
    end
    # rubocop:enable RSpec/ExampleLength
  end
end
