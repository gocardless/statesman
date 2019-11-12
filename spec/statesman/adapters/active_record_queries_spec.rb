require "spec_helper"

describe Statesman::Adapters::ActiveRecordQueries, active_record: true do
  def configure(klass, transition_class, **more)
    klass.send(
      :include,
      described_class[
        transition_class: transition_class,
        initial_state: :initial,
        **more
      ],
    )
  end

  before do
    prepare_model_table
    prepare_transitions_table
    prepare_other_model_table
    prepare_other_transitions_table

    Statesman.configure { storage_adapter(Statesman::Adapters::ActiveRecord) }

    configure(MyActiveRecordModel, MyActiveRecordModelTransition, **extra_options1)
    configure(OtherActiveRecordModel, OtherActiveRecordModelTransition)

    MyActiveRecordModel.send(:has_one, :other_active_record_model)
    OtherActiveRecordModel.send(:belongs_to, :my_active_record_model)
  end

  after { Statesman.configure { storage_adapter(Statesman::Adapters::Memory) } }

  let(:extra_options1) { {} }

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
    let(:extra_options1) { { transition_class: OtherActiveRecordModelTransition } }

    before do
      # Switch to using OtherActiveRecordModelTransition, so the existing
      # relation with MyActiveRecordModelTransition doesn't interfere with
      # this spec.
      MyActiveRecordModel.send(:has_many,
                               :custom_name,
                               class_name: "OtherActiveRecordModelTransition")
    end

    describe ".in_state" do
      subject(:query) { MyActiveRecordModel.in_state(:succeeded) }

      specify { expect { query }.to_not raise_error }
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

  describe "check_missing_methods!" do
    subject(:check_missing_methods!) { described_class.check_missing_methods!(base) }

    context "when base has no missing methods" do
      let(:base) do
        Class.new do
          def self.transition_class; end

          def self.initial_state; end
        end
      end

      it "does not raise an error" do
        expect { check_missing_methods! }.to_not raise_exception(NotImplementedError)
      end
    end

    context "when base has missing methods" do
      let(:base) do
        Class.new
      end

      it "raises an error" do
        expect { check_missing_methods! }.to raise_exception(NotImplementedError)
      end
    end
  end
end
