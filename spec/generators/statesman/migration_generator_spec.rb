require "spec_helper"
require "support/generators_shared_examples"
require "generators/statesman/migration_generator"

describe Statesman::MigrationGenerator, type: :generator do
  it_behaves_like "a generator" do
    let(:migration_name) { "db/migrate/add_statesman_to_bacon_transitions.rb" }
  end

  describe "the model contains the correct words" do
    subject(:migration) do
      file(
        "db/migrate/#{migration_number}_add_statesman_to_bacon_transitions.rb",
      )
    end

    let(:migration_number) { "5678309" }

    let(:mock_time) do
      double("Time", utc: double("UTCTime", strftime: migration_number))
    end

    before do
      allow(Time).to receive(:now).and_return(mock_time)
      run_generator %w[Yummy::Bacon Yummy::BaconTransition]
    end

    it { is_expected.to contain(/:bacon_transition/) }
    it { is_expected.to_not contain(%r{:yummy/bacon}) }
    it { is_expected.to contain(/null: false/) }

    it "names the sorting index appropriately" do
      expect(migration).
        to contain("name: \"index_bacon_transitions_parent_sort\"")
    end

    it "names the most_recent index appropriately" do
      expect(migration).
        to contain("name: \"index_bacon_transitions_parent_most_recent\"")
    end
  end
end
