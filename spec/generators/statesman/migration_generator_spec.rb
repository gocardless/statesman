require "spec_helper"
require "support/generators_shared_examples"
require "generators/statesman/migration_generator"

describe Statesman::MigrationGenerator, type: :generator do
  it_behaves_like "a generator" do
    let(:migration_name) { 'db/migrate/add_statesman_to_bacon_transitions.rb' }
  end

  let(:migration_number) { '5678309' }

  let(:mock_time) do
    double('Time', utc: double('UTCTime', strftime: migration_number))
  end

  describe 'the model contains the correct words' do
    subject do
      file(
        "db/migrate/#{migration_number}_add_statesman_to_bacon_transitions.rb"
      )
    end

    before do
      allow(Time).to receive(:now).and_return(mock_time)
      run_generator %w[Yummy::Bacon Yummy::BaconTransition]
    end

    it { is_expected.to contain(/:bacon_transition/) }
    it { is_expected.not_to contain(%r{:yummy/bacon}) }
    it { is_expected.to contain(/null: false/) }

    it "names the sorting index appropriately" do
      expect(subject).
        to contain("name: \"index_bacon_transitions_parent_sort\"")
    end

    it "names the most_recent index appropriately" do
      expect(subject).
        to contain("name: \"index_bacon_transitions_parent_most_recent\"")
    end
  end

  describe "properly inherit class" do
    subject do
      file(
        "db/migrate/#{migration_number}_add_statesman_to_bacon_transitions.rb"
      )
    end

    let(:rails_version) { nil }

    before do
      allow(Time).to receive(:now).and_return(mock_time)
      expect(Rails).to receive(:version).and_return(rails_version)
      run_generator %w(Yummy::Bacon Yummy::BaconTransition)
    end

    context "on Rails 4" do
      let(:rails_version) { "4.1.14" }

      it { is_expected.not_to contain(/ActiveRecord::Migration\[\d+\.\d+\]/) }
    end

    context "on Rails 5" do
      let(:rails_version) { "5.1.0" }

      it { is_expected.to contain(/ActiveRecord::Migration\[\d+\.\d+\]/) }
    end
  end
end
