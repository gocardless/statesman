# frozen_string_literal: true

require "support/generators_shared_examples"
require "generators/statesman/migration_generator"
require "rails/generators/testing/behavior"

describe Statesman::MigrationGenerator, type: :generator do
  before do
    stub_const("Yummy::Bacon", Class.new(ActiveRecord::Base))
    stub_const("Yummy::BaconTransition", Class.new(ActiveRecord::Base))
  end

  around { |e| Timecop.freeze(Time.parse("2025-01-01 00:00:00"), &e) }

  it_behaves_like "a generator" do
    let(:migration_name) { "db/migrate/20250101000000_add_statesman_to_yummy_bacon_transitions.rb" }
  end

  describe "the model contains the correct words" do
    subject(:migration) do
      file(
        "db/migrate/20250101000000_add_statesman_to_yummy_bacon_transitions.rb",
      )
    end

    before do
      run_generator %w[Yummy::Bacon Yummy::BaconTransition]
    end

    it { is_expected.to contain(/:yummy_bacon_transition/) }
    it { is_expected.to contain(/null: false/) }

    it "names the sorting index appropriately" do
      expect(migration).
        to contain("name: \"index_yummy_bacon_transitions_parent_sort\"")
    end

    it "names the most_recent index appropriately" do
      expect(migration).
        to contain("name: \"index_yummy_bacon_transitions_parent_most_recent\"")
    end

    it "uses the right column type for Postgres", if: postgres? do
      expect(migration).to contain(":metadata, :jsonb")
    end

    it "uses the right column type for MySQL", if: mysql? do
      expect(migration).to contain(":metadata, :json")
    end

    it "uses the right column type for SQLite", if: sqlite? do
      expect(migration).to contain(":metadata, :json")
    end
  end
end
