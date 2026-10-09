# frozen_string_literal: true

describe Statesman::Adapters::ActiveRecordQueries, :active_record do
  def configure_old(klass, transition_class)
    klass.define_singleton_method(:transition_class) { transition_class }
    klass.define_singleton_method(:initial_state) { :initial }
    klass.send(:include, described_class)
  end

  def configure_new(klass, transition_class)
    klass.send(:include, described_class[transition_class: transition_class,
                                         initial_state: :initial])
  end

  before do
    prepare_model_table
    prepare_transitions_table
    prepare_other_model_table
    prepare_other_transitions_table

    Statesman.configure do
      storage_adapter(Statesman::Adapters::ActiveRecord)
    end
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

  shared_examples "testing methods" do
    before do
      case config_type
      when :old
        configure_old(MyActiveRecordModel, MyActiveRecordModelTransition)
        configure_old(OtherActiveRecordModel, OtherActiveRecordModelTransition)
      when :new
        configure_new(MyActiveRecordModel, MyActiveRecordModelTransition)
        configure_new(OtherActiveRecordModel, OtherActiveRecordModelTransition)
      else
        raise "Unknown config type #{config_type}"
      end

      MyActiveRecordModel.send(:has_one, :other_active_record_model)
      OtherActiveRecordModel.send(:belongs_to, :my_active_record_model)
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
          expect(not_in_state).to contain_exactly(initial_state_model,
                                                  returned_to_initial_model)
        end
      end

      context "given an array of states" do
        subject(:not_in_state) { MyActiveRecordModel.not_in_state(%i[succeeded failed]) }

        it do
          expect(not_in_state).to contain_exactly(initial_state_model,
                                                  returned_to_initial_model)
        end
      end
    end

    describe ".bulk_transition_to!" do
      # On top of whatever the outer `let!`s already left in :initial (initial_state_model,
      # returned_to_initial_model), so every assertion below snapshots the live scope rather
      # than hardcoding a count coupled to fixtures this block doesn't own.
      let(:expected) { MyActiveRecordModel.in_state(:initial).to_a }

      before { expected } # snapshot before any example mutates which rows are in :initial

      it "transitions every row currently in that state, returning a successful Result" do
        result = MyActiveRecordModel.in_state(:initial).bulk_transition_to!(:succeeded)

        expect(result).to be_success
        expect(result.successful).to match_array(expected)
        expect(expected.map { |m| m.reload.state_machine.current_state }).to all(eq("succeeded"))
      end

      it "processes every matching row across multiple chunks, with no skips or duplicates" do
        result = MyActiveRecordModel.in_state(:initial).bulk_transition_to!(:succeeded, batch_size: 1)

        expect(result.successful).to match_array(expected)
        expect(result.failed).to be_empty
      end

      it "hydrates records per chunk rather than loading the whole relation upfront" do
        expect(MyActiveRecordModel).to receive(:unscoped).exactly(expected.size).times.and_call_original

        MyActiveRecordModel.in_state(:initial).bulk_transition_to!(:succeeded, batch_size: 1)
      end

      it "builds one Statesman::BulkTransition::Item per row, from #state_machine" do
        captured_items = nil
        allow(Statesman::BulkTransition).to receive(:call).and_wrap_original do |original, items, **opts|
          captured_items = items
          original.call(items, **opts)
        end

        MyActiveRecordModel.in_state(:initial).bulk_transition_to!(:succeeded)

        expect(captured_items).to all(be_a(Statesman::BulkTransition::Item))
        expect(captured_items.map { |item| item.machine.object }).to match_array(expected)
      end

      it "forwards from_state/to_state/other options through to BulkTransition.call" do
        expect(Statesman::BulkTransition).to receive(:call).and_wrap_original do |original, items, **opts|
          expect(opts).to include(from_state: "initial", to_state: :succeeded,
                                  metadata: { "batch_id" => 42 }, skip_guards: true)
          original.call(items, **opts)
        end

        MyActiveRecordModel.in_state(:initial).
          bulk_transition_to!(:succeeded, metadata: { "batch_id" => 42 }, skip_guards: true)
      end

      context "when a row leaves the scope between the snapshot and its chunk's hydration" do
        before do
          original_unscoped = MyActiveRecordModel.method(:unscoped)
          target_id = returned_to_initial_model.id
          target_model = returned_to_initial_model
          raced = false

          allow(MyActiveRecordModel).to receive(:unscoped) do
            relation = original_unscoped.call
            relation.define_singleton_method(:where) do |*args|
              ids_in_batch = args.first.is_a?(Hash) ? args.first.values.first : nil
              if !raced && ids_in_batch&.include?(target_id)
                raced = true
                target_model.state_machine.transition_to!(:failed)
              end
              super(*args)
            end
            relation
          end
        end

        it "reports the row as a conflict, neither silently dropped nor double-processed" do
          result = MyActiveRecordModel.in_state(:initial).bulk_transition_to!(:succeeded, batch_size: 1)

          expect(result.successful).to contain_exactly(initial_state_model)
          expect(result.failed.map(&:object)).to contain_exactly(returned_to_initial_model)
          expect(result.failed.first.reason).to eq(:conflict)
        end
      end

      it "raises a helpful error when batch_size is not a positive integer" do
        expect { MyActiveRecordModel.in_state(:initial).bulk_transition_to!(:succeeded, batch_size: 0) }.
          to raise_error(ArgumentError, /batch_size/)
      end

      it "raises when called with no in_state chained" do
        expect { MyActiveRecordModel.bulk_transition_to!(:succeeded) }.
          to raise_error(ArgumentError, /in_state/)
      end

      it "raises when chained after not_in_state instead of in_state" do
        expect { MyActiveRecordModel.not_in_state(:succeeded).bulk_transition_to!(:failed) }.
          to raise_error(ArgumentError, /in_state/)
      end

      it "raises when in_state was given more than one state" do
        expect { MyActiveRecordModel.in_state(:initial, :failed).bulk_transition_to!(:succeeded) }.
          to raise_error(ArgumentError, /in_state/)
      end

      context "when the model doesn't define #state_machine" do
        before do
          stub_const("ModelWithoutStateMachine", Class.new(ActiveRecord::Base) do
            self.table_name = "my_active_record_models"
            has_many :my_active_record_model_transitions,
                     class_name: "MyActiveRecordModelTransition",
                     foreign_key: :my_active_record_model_id,
                     autosave: false

            include Statesman::Adapters::ActiveRecordQueries[
              transition_class: MyActiveRecordModelTransition,
              initial_state: :initial,
            ]
          end)
        end

        it "raises a helpful error" do
          expect { ModelWithoutStateMachine.in_state(:initial).bulk_transition_to!(:succeeded) }.
            to raise_error(NotImplementedError, /state_machine/)
        end
      end

      context "with a model that has more than one state machine" do
        before do
          stub_const("ModelWithTwoStateMachines", Class.new(ActiveRecord::Base) do
            self.table_name = "my_active_record_models"
            has_many :my_active_record_model_transitions,
                     class_name: "MyActiveRecordModelTransition",
                     foreign_key: :my_active_record_model_id,
                     autosave: false

            include Statesman::Adapters::ActiveRecordQueries[
              transition_class: MyActiveRecordModelTransition,
              initial_state: :initial,
            ]

            def state_machine_a
              @state_machine_a ||= MyStateMachine.new(self, transition_class: MyActiveRecordModelTransition)
            end

            def state_machine_b
              @state_machine_b ||= MyStateMachine.new(self, transition_class: MyActiveRecordModelTransition)
            end
          end)
        end

        it "resolves the machine via machine_method: rather than a default #state_machine" do
          row = ModelWithTwoStateMachines.create

          result = ModelWithTwoStateMachines.in_state(:initial).
            bulk_transition_to!(:succeeded, machine_method: :state_machine_b)

          expect(result).to be_success
          expect(row.reload.state_machine_b.current_state).to eq("succeeded")
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

    context "with a custom primary key for the model" do
      before do
        # Switch to using OtherActiveRecordModelTransition, so the existing
        # relation with MyActiveRecordModelTransition doesn't interfere with
        # this spec.
        # Configure the relationship to use a different primary key,
        MyActiveRecordModel.send(:has_many,
                                 :custom_name,
                                 class_name: "OtherActiveRecordModelTransition",
                                 primary_key: :external_id)

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

      it do
        expect do
          ActiveRecord::Base.transaction do
            model.state_machine.transition_to!(:succeeded)
            raise ActiveRecord::Rollback
          end
        end.to_not change(MyStateMachine, :after_commit_callback_executed)
      end
    end
  end

  context "using old configuration method" do
    let(:config_type) { :old }

    it_behaves_like "testing methods"
  end

  context "using new configuration method" do
    let(:config_type) { :new }

    it_behaves_like "testing methods"
  end

  context "with no association with the transition class" do
    before do
      class UnknownModelTransition < OtherActiveRecordModelTransition; end

      configure_old(MyActiveRecordModel, UnknownModelTransition)
    end

    describe ".in_state" do
      subject(:query) { MyActiveRecordModel.in_state(:succeeded) }

      it "raises a helpful error" do
        expect { query }.to raise_error(Statesman::MissingTransitionAssociation)
      end
    end
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
        expect { check_missing_methods! }.to_not raise_exception
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
