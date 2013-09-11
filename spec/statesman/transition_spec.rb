require "spec_helper"

describe Statesman::Transition do
  describe "#initialize" do
    let(:from) { :x }
    let(:to) { :y }
    let(:create) { Statesman::Transition.new(from, to) }

    specify { expect(create.from).to equal(from) }
    specify { expect(create.to).to equal(to) }
    specify { expect(create.created_at).to be_a(Time) }

    context "with metadata passed" do
      let(:metadata) { { some: :hash } }
      let(:create) { Statesman::Transition.new(from, to, metadata) }

      specify { expect(create.metadata).to eq(metadata) }
    end
  end
end
