require "spec_helper"
require "support/generators_shared_examples"
require "generators/statesman/active_record_transition_generator"

describe Statesman::ActiveRecordTransitionGenerator, type: :generator do
  it_behaves_like "a generator" do
    let(:migration_name) { 'db/migrate/create_bacon_transitions.rb' }
  end

  describe 'properly adds class names' do
    before { run_generator %w(Yummy::Bacon Yummy::BaconTransition) }
    subject { file('app/models/yummy/bacon_transition.rb') }

    it { is_expected.to contain(/:bacon_transition/) }
    it { is_expected.not_to contain(/:yummy\/bacon/) }
    it { is_expected.to contain(/class_name: 'Yummy::Bacon'/) }
  end

  describe 'properly formats without class names' do
    before { run_generator %w(Bacon BaconTransition) }
    subject { file('app/models/bacon_transition.rb') }

    it { is_expected.not_to contain(/class_name:/) }
    it { is_expected.to contain(/class BaconTransition/) }
  end
end
