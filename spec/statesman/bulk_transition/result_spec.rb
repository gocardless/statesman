# frozen_string_literal: true

describe Statesman::BulkTransition::Result do
  subject(:result) { described_class.new(transitioned: transitioned, failed: failed) }

  let(:transitioned) { [] }
  let(:failed) { [] }

  describe "defaults" do
    subject(:result) { described_class.new }

    its(:transitioned) { is_expected.to eq([]) }
    its(:failed) { is_expected.to eq([]) }
    its(:success?) { is_expected.to be(true) }
  end

  describe "#transitioned" do
    let(:transitioned) { [double, double] }

    its(:transitioned) { is_expected.to eq(transitioned) }
  end

  describe "#failed" do
    let(:failed) { [double] }

    its(:failed) { is_expected.to eq(failed) }
  end

  describe "#success?" do
    context "when nothing failed" do
      its(:success?) { is_expected.to be(true) }
    end

    context "when something failed" do
      let(:failed) { [double] }

      its(:success?) { is_expected.to be(false) }
    end
  end
end
