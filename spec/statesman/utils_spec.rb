require "spec_helper"

describe Statesman::Utils do
  describe ".rails_major_version" do
    subject { described_class.rails_major_version }

    context "for Rails 4" do
      before { allow(Rails).to receive(:version).and_return("4.1.2") }

      it { is_expected.to eq(4) }
    end

    context "for Rails 5" do
      before { allow(Rails).to receive(:version).and_return("5.0.0") }

      it { is_expected.to eq(5) }
    end
  end

  describe ".rails_5_or_higher?" do
    subject { described_class.rails_5_or_higher? }

    context "for a pre-Rails 5 Rails version" do
      before { allow(Rails).to receive(:version).and_return("4.1.2") }

      it { is_expected.to be(false) }
    end

    context "for Rails 5 or a later version" do
      before { allow(Rails).to receive(:version).and_return("5.0.0") }

      it { is_expected.to be(true) }
    end
  end

  describe ".rails_4_or_higher?" do
    subject { described_class.rails_4_or_higher? }

    context "for a pre-Rails 4 Rails version" do
      before { allow(Rails).to receive(:version).and_return("3.0.0") }

      it { is_expected.to be(false) }
    end

    context "for Rails 4 or a later version" do
      before { allow(Rails).to receive(:version).and_return("4.1.2") }

      it { is_expected.to be(true) }
    end
  end
end
