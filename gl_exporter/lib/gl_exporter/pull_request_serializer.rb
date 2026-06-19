# frozen_string_literal: true
class GlExporter

  # Serializes Pull Requests from GitLab's Merge Requests
  #
  # #### Model Example:
  #
  # ```
  # {"id"=>476834,
  #  "iid"=>2,
  #  "project_id"=>1169162,
  #  "title"=>"WIP: this one'll really be about what the branch name says",
  #  "description"=>"Please report this. To verizon. Or the NSA.",
  #  "state"=>"reopened",
  #  "created_at"=>"2016-05-10T22:20:29.649Z",
  #  "updated_at"=>"2016-05-11T22:56:02.597Z",
  #  "target_branch"=>"master",
  #  "source_branch"=>"omniauth-login",
  #  "upvotes"=>0,
  #  "downvotes"=>0,
  #  "author"=>
  #   {"name"=>"Matt",
  #    "username"=>"spraints",
  #    "id"=>142189,
  #    "state"=>"active",
  #    "avatar_url"=>"https://secure.gravatar.com/avatar/0bf208eebdab7c5d16152f70a1ee837f?s=80&d=identicon",
  #    "web_url"=>"https://gitlab.com/u/spraints"},
  #  "assignee"=>
  #   {"name"=>"Matt",
  #    "username"=>"spraints",
  #    "id"=>142189,
  #    "state"=>"active",
  #    "avatar_url"=>"https://secure.gravatar.com/avatar/0bf208eebdab7c5d16152f70a1ee837f?s=80&d=identicon",
  #    "web_url"=>"https://gitlab.com/u/spraints"},
  #  "source_project_id"=>1169162,
  #  "target_project_id"=>1169162,
  #  "labels"=>["Blocker", "Don't Drink and Code"],
  #  "work_in_progress"=>true,
  #  "milestone"=>
  #   {"id"=>62677,
  #    "iid"=>1,
  #    "project_id"=>1169162,
  #    "title"=>"Prototype",
  #    "description"=>"Just get the simplest thing working and out there for folks to try out.",
  #    "state"=>"active",
  #    "created_at"=>"2016-05-10T22:06:45.481Z",
  #    "updated_at"=>"2016-05-10T22:06:45.481Z",
  #    "due_date"=>"2020-04-20"},
  #  "merge_when_build_succeeds"=>false,
  #  "merge_status"=>"can_be_merged",
  #  "subscribed"=>true}
  # ```
  class PullRequestSerializer < BaseSerializer

    # @see GlExporter::BaseSerializer#to_gh_hash
    def to_gh_hash
      {
        type: "pull_request",
        url: url,
        user: user,
        repository: repository,
        title: title,
        body: body,
        base: base,
        head: head,
        assignee: assignee,
        milestone: milestone,
        labels: labels,
        merged_at: merged_at,
        closed_at: closed_at,
        created_at: created_at
      }
    end

    # Pull Requests require that the repository be attached before serialization
    def valid?(gl_model)
      gl_model["repository"]
    end

    private

    def url
      url_for_model(gl_model, type: "pull_request")
    end

    def user
      url_for_model(gl_model["author"])
    end

    def repository
      url_for_model(gl_model["repository"])
    end

    def title
      gl_model["title"]
    end

    def body
      gl_model["description"]
    end

    def base
      {
        ref: gl_model["target_branch"],
        sha: base_sha,
        user: url_for_model(gl_model["owner"]),
        repo: repository
      }
    end

    def base_sha
      if diff_refs_present?
        GlExporter.output_logger.debug("MR #{gl_model["id"]} using base_sha from diff_refs")
        gl_model["diff_refs"]["base_sha"]
      elsif first_commit_info = gl_model["commits"]&.last
        GlExporter.output_logger.debug("MR #{gl_model["id"]} using base_sha from first commit info")
        parent_oid(first_commit_info["id"])
      end
    end

    def parent_oid(oid)
      if first_commit = Gitlab.commit(gl_model["project_id"], oid)
        first_commit["parent_ids"].first
      end
    end

    def head
      {
        ref: gl_model["source_branch"],
        sha: head_sha,
        user: url_for_model(gl_model["owner"]),
        repo: repository
      }
    end

    def head_sha
      if is_squash_merge? && gl_model["state"] == "merged"
        squash_commit_sha
      elsif diff_refs_present?
        GlExporter.output_logger.debug("MR #{gl_model["id"]} using head_sha from diff_refs")
        gl_model["diff_refs"]["head_sha"]
      elsif last_commit_info = gl_model["commits"]&.first
        GlExporter.output_logger.debug("MR #{gl_model["id"]} using head_sha from last commit info")
        last_commit_info["id"]
      end
    end

    def assignee
      return unless gl_model["assignee"]
      url_for_model(gl_model["assignee"])
    end

    def milestone
      return unless gl_model["milestone"]
      gl_model["milestone"]["repository"] = gl_model["repository"]
      url_for_model(gl_model["milestone"], type: "milestone")
    end

    def labels
      gl_model["labels"].map do |label_name|
        label = {
          "name"       => label_name,
          "repository" => gl_model["repository"],
        }
        url_for_model(label, type: "label")
      end
    end

    def merged_at
      if gl_model["state"] == "merged"
        gl_model["updated_at"]
      end
    end

    def closed_at
      if ["closed", "merged"].include?(gl_model["state"])
        gl_model["updated_at"]
      end
    end

    def created_at
      gl_model["created_at"]
    end

    def rugged
      @rugged ||= Rugged::Repository.new(gl_model["repo_path"])
    end

    # Checks if the merge request has a squash commit with guards
    # against nil or empty commits.
    #
    # @return [Boolean] true if the merge request has a squash commit
    def is_squash_merge?
      return false if no_commits?

      gl_model["squash"] == true
    end

    def no_commits?
      if diff_refs_present?
        gl_model["diff_refs"]["base_sha"] == gl_model["diff_refs"]["head_sha"]
      else
        gl_model["commits"].nil? || gl_model["commits"].empty?
      end
    end

    def diff_refs_present?
      gl_model["diff_refs"] &&
        gl_model["diff_refs"]["base_sha"] &&
        gl_model["diff_refs"]["head_sha"]
    end

    def squash_commit_sha
      if gl_model["squash_commit_sha"]
        GlExporter.output_logger.debug("MR #{gl_model["id"]} using squash_commit_sha")
        gl_model["squash_commit_sha"]
      else
        GlExporter.output_logger.debug("MR #{gl_model["id"]} using merge_commit_sha as fallback for squash_commit_sha")
        gl_model["merge_commit_sha"]
      end
    end
  end
end
