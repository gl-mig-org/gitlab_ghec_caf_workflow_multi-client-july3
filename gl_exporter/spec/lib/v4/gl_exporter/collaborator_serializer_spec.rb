# frozen_string_literal: true
require "spec_helper"

describe GlExporter::CollaboratorSerializer, :v4 do
  let(:access_level) { nil } # default to nil, use what's in the cassette unless we explicitly override
  let(:project_team_member) do
    VCR.use_cassette("v4/gitlab-project_team_member/Mouse-Hack/hugo-pages") do
      Gitlab.project_team_members(project["id"]).first.tap do |member|
        member["access_level"] = access_level if access_level
      end
    end
  end

  let(:project) do
    VCR.use_cassette("v4/gitlab-projects/Mouse-Hack/hugo-pages") do
      Gitlab.project("Mouse-Hack", "hugo-pages")
    end
  end

  subject { described_class.new }

  describe "#serialize" do
    subject { described_class.new.serialize(project_team_member) }

    it "returns a serialized collaborator hash" do
      expected = {
        user: "https://gitlab.com/spraints",
        permission: "maintain"
      }

      expected.each do |key, value|
        expect(subject[key]).to eq(value),
                                "`#{key}` does not match \n\n  expected: #{value.inspect}\n       got: #{subject[key].inspect}\n"
      end
    end

    describe "with access_level 5" do
      # We override 5 -> 10/read
      let(:access_level) { 5 }

      it { is_expected.to include(permission: "read") }
    end

    describe "with access_level 15" do
      # We override 15 -> 10/read
      let(:access_level) { 15 }

      it { is_expected.to include(permission: "read") }
    end

    describe "with access_level 20" do
      # 20 is not overridden - it maps to "triage"
      let(:access_level) { 20 }

      it { is_expected.to include(permission: "triage") }
    end

    describe "with invalid/unmapped access_level" do
      let(:access_level) { 9999 }

      it { is_expected.to be_nil }
    end
  end
end
