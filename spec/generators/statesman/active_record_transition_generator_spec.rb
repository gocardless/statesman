require "spec_helper"
require "support/generators_shared_examples"
require "generators/statesman/active_record_transition_generator"

describe Statesman::ActiveRecordTransitionGenerator, type: :generator do

  it_behaves_like "a generator" do
    let(:migration_name) { 'db/migrate/create_bacon_transitions.rb' }
  end

  describe 'the model contains the correct words' do
    before { run_generator %w[Yummy::Bacon Yummy::BaconTransition] } 
    subject { file('app/models/yummy/bacon_transition.rb') }
    
    it { should contain(%r[:bacon_transition]) }
    it { should_not contain(%r[:yummy/bacon]) }
    it { should contain(%r[class_name: 'Yummy::Bacon']) }
  end
  
  describe 'the model contains the correct words' do
    before { run_generator %w[Bacon BaconTransition] } 
    subject { file('app/models/bacon_transition.rb') }

    it { should_not contain(%r[class_name:]) }
    it { should contain(%r[class BaconTransition]) }
  end

end
