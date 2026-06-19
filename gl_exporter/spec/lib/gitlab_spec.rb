# frozen_string_literal: true
require "spec_helper"

describe Gitlab do
  describe ".project_uploads_api_available?" do
    before(:each) do
      described_class.instance_variable_set(:@gitlab_version, nil)
      allow(described_class).to receive(:api_v3?).and_return(false)
    end

    after(:each) do
      described_class.instance_variable_set(:@gitlab_version, nil)
    end

    context "when GitLab version is >= 17.4" do
      it "is true for the introduction version" do
        described_class.instance_variable_set(:@gitlab_version, "17.4.0")
        expect(described_class.project_uploads_api_available?).to eq(true)
      end

      it "is true for higher versions" do
        described_class.instance_variable_set(:@gitlab_version, "17.10.2-ee")
        expect(described_class.project_uploads_api_available?).to eq(true)
      end
    end

    context "when GitLab version is < 17.4" do
      it "is false for 17.3.99" do
        described_class.instance_variable_set(:@gitlab_version, "17.3.99")
        expect(described_class.project_uploads_api_available?).to eq(false)
      end

      it "is false for an older self-managed version" do
        described_class.instance_variable_set(:@gitlab_version, "15.6.0")
        expect(described_class.project_uploads_api_available?).to eq(false)
      end
    end

    context "when the version cannot be parsed" do
      it "is false rather than raising" do
        described_class.instance_variable_set(:@gitlab_version, nil)
        allow(described_class).to receive(:version).and_return({ "version" => "unknown" })
        expect(described_class.project_uploads_api_available?).to eq(false)
      end
    end

    context "when API v3 is in use" do
      it "is false even on a recent version" do
        described_class.instance_variable_set(:@gitlab_version, "17.10.0")
        allow(described_class).to receive(:api_v3?).and_return(true)
        expect(described_class.project_uploads_api_available?).to eq(false)
      end
    end
  end

  describe ".gitlab_version" do
    after(:each) do
      described_class.instance_variable_set(:@gitlab_version, nil)
    end

    it "extracts a normalized version string from the API payload" do
      described_class.instance_variable_set(:@gitlab_version, nil)
      allow(described_class).to receive(:version).and_return({ "version" => "17.3.7-ee" })
      expect(described_class.gitlab_version).to eq("17.3.7")
    end

    it "caches the lookup so the API is queried once" do
      described_class.instance_variable_set(:@gitlab_version, nil)
      expect(described_class).to receive(:version).once.and_return({ "version" => "18.10.1-ee" })
      2.times { described_class.gitlab_version }
      expect(described_class.gitlab_version).to eq("18.10.1")
    end

    it "caches an unparseable payload so the API is queried once" do
      described_class.instance_variable_set(:@gitlab_version, nil)
      expect(described_class).to receive(:version).once.and_return({ "version" => "unknown" })
      2.times { described_class.gitlab_version }
      expect(described_class.gitlab_version).to eq("")
    end

    it "returns an empty string without raising when the payload has no version key" do
      described_class.instance_variable_set(:@gitlab_version, nil)
      allow(described_class).to receive(:version).and_return({})
      expect(described_class.gitlab_version).to eq("")
    end
  end
end
