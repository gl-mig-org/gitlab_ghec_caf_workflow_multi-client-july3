# frozen_string_literal: true
require "spec_helper"

describe GlExporter::PullRequestSerializer, :v4 do
  let(:merge_request) do
    VCR.use_cassette("v4/gitlab-merge-request") do
      Gitlab.merge_request(1169162, 2)
    end
  end

  let(:project) do
    VCR.use_cassette("v4/gitlab-projects/Mouse-Hack/hugo-pages") do
      Gitlab.project("Mouse-Hack", "hugo-pages")
    end
  end

  let(:group) do
    VCR.use_cassette("v4/gitlab-export-owner/Mouse-Hack/hugo-pages") do
      Gitlab.group("Mouse-Hack")
    end
  end

  let(:commits) do
    VCR.use_cassette("v4/gitlab-merge-request-commits/Mouse-Hack/hugo-pages") do
      Gitlab.merge_request_commits(1169162, 2)
    end
  end

  describe "#serialize" do
    let(:pull_request_serializer) { described_class.new }
    subject { pull_request_serializer.serialize(merge_request) }

    before(:each) do
      allow(pull_request_serializer).to receive(:parent_oid).and_return("3a1811f3cb96e9bc426f6ee3544a2cf4f7d5f3fd")
      merge_request["repository"] = project
      merge_request["owner"] = group
      merge_request["commits"] = commits
    end

    it "returns a serialized Issue hash" do
      expected = {
          type: "pull_request",
          url: "https://gitlab.com/Mouse-Hack/hugo-pages/merge_requests/2",
          repository: "https://gitlab.com/Mouse-Hack/hugo-pages",
          user: "https://gitlab.com/spraints",
          title: "WIP: this one'll really be about what the branch name says",
          body: %{Please report this. To verizon. Or the NSA.},
          base: {
            ref: "master",
            sha: "3a1811f3cb96e9bc426f6ee3544a2cf4f7d5f3fd",
            user: "https://gitlab.com/groups/Mouse-Hack",
            repo: "https://gitlab.com/Mouse-Hack/hugo-pages"
          },
          head: {
            ref: "omniauth-login",
            sha: "c222af415ecc78c644c139cbf5eb44a25205cbad",
            user: "https://gitlab.com/groups/Mouse-Hack",
            repo: "https://gitlab.com/Mouse-Hack/hugo-pages"
          },
          assignee: "https://gitlab.com/spraints",
          milestone: "https://gitlab.com/Mouse-Hack/hugo-pages/milestones/1",
          labels: [
            "https://gitlab.com/Mouse-Hack/hugo-pages/labels#/Blocker",
            "https://gitlab.com/Mouse-Hack/hugo-pages/labels#/Don%27t+Drink+and+Code"
          ],
          merged_at: nil,
          closed_at: nil,
          created_at: "2016-05-10T22:20:29.649Z"
        }

      expected.each do |key, value|
        expect(subject[key]).to eq(value)
      end
    end

    context "with a closed merge request" do
      let(:merge_request) do
        VCR.use_cassette("v4/gitlab-closed-merge-request") do
          Gitlab.merge_request(1169162, 3)
        end
      end

      it "has a closed_at equal to updated_at" do
        expect(subject[:closed_at]).to eq(merge_request["updated_at"])
      end
    end

    context "with a merged merge request" do
      let(:merge_request) do
        VCR.use_cassette("v4/gitlab-merged-merge-request") do
          Gitlab.merge_request(1169162, 1)
        end
      end

      it "has a merged_at and closed_at equal to updated_at" do
        expect(subject[:closed_at]).to eq(merge_request["updated_at"])
        expect(subject[:merged_at]).to eq(merge_request["updated_at"])
      end
    end

    context "with a squash-merge merge request" do
      let(:repository) { { "id" => 1, "name" => "test-repo" } }
      let(:owner) { { "id" => 1, "username" => "test-owner" } }
      let(:commits) { [{ "id" => "commitsha123" }] }
      let(:base_merge_request) do
        {
          "id" => 123,
          "iid" => 1,
          "title" => "Test PR",
          "description" => "Test description",
          "state" => "merged",
          "created_at" => "2022-01-01T00:00:00Z",
          "updated_at" => "2022-01-02T00:00:00Z",
          "target_branch" => "master",
          "source_branch" => "feature",
          "labels" => [],
          "author" => { "username" => "author" },
          "repository" => repository,
          "owner" => owner,
          "commits" => commits,
          "project_id" => 1,
          "repo_path" => "/tmp/repo",
          "squash" => false,
          "squash_commit_sha" => "squashsha123",
        }
      end

      context "when commits are empty (this should never happen)" do
        let(:commits) { [] }

        it "gets head SHA from diff_refs" do
          expect(subject[:head][:sha]).to eq(merge_request["diff_refs"]["head_sha"])
        end

        it "returns nil if there are no diff_refs" do
          merge_request.delete("diff_refs")
          expect(subject[:head][:sha]).to be_nil
        end
      end

      context "when commits is nil" do
        let(:commits) { nil }

        it "gets head SHA from diff_refs" do
          expect(subject[:head][:sha]).to eq(merge_request["diff_refs"]["head_sha"])
        end

        it "returns nil if there are no diff_refs" do
          merge_request.delete("diff_refs")
          expect(subject[:head][:sha]).to be_nil
        end
      end

      context "when commits are not empty" do
        context "when squash flag is true" do
          let(:merge_request) { base_merge_request.merge("squash" => true) }

          it "head sha is squash_commit_sha" do
            expect(subject[:head][:sha]).to eq(merge_request["squash_commit_sha"])
          end

          context "when merge request is unmerged" do
            let(:merge_request) { base_merge_request.merge("state" => "opened", "squash_commit_sha" => nil) }

            it "head sha is non-nil" do
              expect(subject[:head][:sha].nil?).to be false
            end
          end
        end

        context "when squash flag is false" do
          let(:merge_request) { base_merge_request.merge("squash" => false) }

          it "head sha is first commit sha" do
            expect(subject[:head][:sha]).to eq(merge_request["commits"].first["id"])
          end
        end
      end
    end
    it "uses diff_refs to determine base_sha if available" do
      merge_request["diff_refs"] = {
        "base_sha" => "abc123",
        "start_sha" => "abc123",
        "head_sha" => "def456"
      }

      expect(subject[:base][:sha]).to eq("abc123")
    end
  end
end
