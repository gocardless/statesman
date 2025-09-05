# frozen_string_literal: true

require "support/generators_shared_examples"
require "generators/statesman/active_record_transition_generator"

describe Statesman::ActiveRecordTransitionGenerator, type: :generator do
  before do
    stub_const("Bacon", Class.new(ActiveRecord::Base))
    stub_const("BaconTransition", Class.new(ActiveRecord::Base))
    stub_const("Yummy::Bacon", Class.new(ActiveRecord::Base))
    stub_const("Yummy::BaconTransition", Class.new(ActiveRecord::Base))
  end

  around { |e| Timecop.freeze(Time.parse("2025-01-01 00:00:00"), &e) }

  it_behaves_like "a generator" do
    let(:migration_name) { "db/migrate/create_yummy_bacon_transitions.rb" }
  end

  describe "creates a migration" do
    subject(:migration) { file("db/migrate/20250101000000_create_yummy_bacon_transitions.rb") }

    before do
      run_generator %w[Yummy::Bacon Yummy::BaconTransition]
    end

    it "includes a foreign key" do
      expect(migration).to contain("add_foreign_key :yummy_bacon_transitions, :yummy_bacons")
    end

    it "uses the right column type for Postgres", if: postgres? do
      expect(migration).to contain("t.jsonb :metadata, default: {}")
    end

    it "uses the right column type for MySQL", if: mysql? do
      expect(migration).to contain("t.json :metadata")
    end

    it "uses the right column type for SQLite", if: sqlite? do
      expect(migration).to contain("t.json :metadata, default: {}")
    end
  end

  describe "properly adds class names" do
    subject { file("app/models/yummy/bacon_transition.rb") }

    before { run_generator %w[Yummy::Bacon Yummy::BaconTransition] }

    it { is_expected.to contain(/:bacon_transitions/) }
    it { is_expected.to contain(/class_name: 'Yummy::Bacon'/) }
  end

  describe "properly formats without class names" do
    subject { file("app/models/bacon_transition.rb") }

    before { run_generator %w[Bacon BaconTransition] }

    it { is_expected.to_not contain(/class_name:/) }
    it { is_expected.to contain(/class BaconTransition/) }
  end

  describe "it doesn't create any double-spacing" do
    subject { file("app/models/yummy/bacon_transition.rb") }

    before { run_generator %w[Yummy::Bacon Yummy::BaconTransition] }

    it { is_expected.to_not contain(/\n\n\n/) }
  end
end
