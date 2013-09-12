require "spec_helper"

describe Statesman::Transition do
  describe "#initialize" do
    let(:to) { :y }
    let(:create) { Statesman::Transition.new(to) }

    specify { expect(create.to_state).to equal(to) }
    specify { expect(create.created_at).to be_a(Time) }

    context "with metadata passed" do
      let(:metadata) { { some: :hash } }
      let(:create) { Statesman::Transition.new(to, metadata) }

      specify { expect(create.metadata).to eq(metadata) }
    end
  end
end
