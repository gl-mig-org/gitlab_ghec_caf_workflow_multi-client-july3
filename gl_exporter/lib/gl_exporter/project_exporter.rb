# frozen_string_literal: true
class GlExporter
  # @!attribute [r] project
  #   @return [Hash] the project to be exported
  # @!attribute [r] archiver
  #   @return [GlExporter::ArchiveBuilder] the instance of the archiver for this export job
  # @!attribute [r] models
  #   @return [Array] the optional model types to be exported
  # @!attribute [r] team_builder
  #   @return [GlExporter::TeamBuilder] the instance of the team builder for this export job
  # @!attribute [r] current_export
  #   @return [GlExporter] the instance of this export job
  # @!attribute [rw] issues
  #   @return [Array] the child issues of the project being exported
  # @!attribute [rw] merge_requests
  #   @return [Array] the child merge requests of the project being exported
  # @!attribute [rw] commit_comments
  #   @return [Array] the child commit comments of the project being exported
  class ProjectExporter
    include Storable
    include Writable
    include Authorable

    attr_reader :project, :archiver, :models, :team_builder, :current_export

    attr_accessor :issues, :merge_requests, :commit_comments, :rewritten_ids

    # Default number of retry attempts when namespace is missing
    NAMESPACE_RETRY_COUNT = 3

    # Exponential backoff delays between retry attempts in seconds (2s, 4s, 8s)
    NAMESPACE_RETRY_DELAYS = [2, 4, 8].freeze
    # Create a new instance of ProjectExporter
    #
    # @param [Hash] project the GitLab project to be exported
    # @param [GlExporter] current_export the current export object
    def initialize(project, current_export: GlExporter.new)
      @project = project
      @current_export = current_export
      @archiver = current_export.archiver
      @models = current_export.models_to_export & OPTIONAL_MODELS
      @team_builder = current_export.team_builder

      @issues = []
      @merge_requests = []
      @commit_comments = []
      @rewritten_ids = {
        issues: {},
        merge_requests: {}
      }
    end

    # Alias for `project`
    #
    # @return [Hash]
    def model
      project
    end

    def project_name
      project["path_with_namespace"]
    end

    def export
      current_export.output_logger.info "Exporting project #{project_name}..."
      export_authenticated_user

      # GitLab is inconsistent with their API where group-owned projects don't
      # have an "owner" attribute.
      project["owner"] = project_owner
      project["labels"] = Gitlab.labels(project["id"])
      project["collaborators"] = export_collaborators
      project["wiki_enabled"] = false unless models.include?("wiki")
      current_export.output_logger.info "Cloning repository..."
      archiver.clone_repo(project)
      # export optional models
      models.each do |model|
        send("export_#{model}")
      end
      export_tags
      export_milestones
      export_protected_branches

      serialize "repository", project

      renumber_issues_and_merge_requests(skip: current_export.without_renumbering)
      rewrite_commit_comment_references_to_issues_and_merge_requests
      export_stored_project_data
    end

    # Serializes and exports data for MigratableResources pertaining to @project
    def export_stored_project_data
      current_export.output_logger.info "Exporting issues, merge requests, and commit comments..."
      [issues, merge_requests, commit_comments].flatten.sort_by(&:created_at).each(&:export)
    end

    # Caches `#export_owner_of_project` in memory
    def project_owner
      @project_owner ||= export_owner_of_project
    end

    # Exports the group or user that owns @project
    #
    # @return [Hash] owner of GitLab Project
    def export_owner_of_project
      ensure_namespace_present!

      if Gitlab.api_v3?
        owner, kind = get_owner_and_kind(project["namespace"]["path"])
      else
        owner, kind = get_owner_and_kind(project["namespace"]["full_path"])
      end
      send("export_#{kind}", owner)
      owner
    end

    # Ensures the project has a valid namespace, retrying if necessary
    #
    # @raise [MissingNamespaceError] if namespace is still missing after all retries
    def ensure_namespace_present!
      return if project["namespace"]

      current_export.output_logger.warn(
        "Project #{project_name} (ID: #{project['id']}) has missing namespace field. " \
        "Attempting to refetch project data."
      )
      log_malformed_project_payload

      NAMESPACE_RETRY_COUNT.times do |attempt|
        delay = NAMESPACE_RETRY_DELAYS[attempt] || NAMESPACE_RETRY_DELAYS.last
        sleep(delay)
        current_export.output_logger.info(
          "Retry attempt #{attempt + 1}/#{NAMESPACE_RETRY_COUNT} for project #{project_name} (waited #{delay}s)"
        )

        refetched_project = Gitlab.project_by_id(project["id"])

        if refetched_project && refetched_project["namespace"]
          current_export.output_logger.info(
            "Successfully retrieved namespace for project #{project_name} on retry #{attempt + 1}"
          )
          @project["namespace"] = refetched_project["namespace"]
          return
        end

        log_malformed_project_payload if refetched_project
      end

      raise MissingNamespaceError.new(project, NAMESPACE_RETRY_COUNT)
    end

    # Logs the malformed project payload for debugging
    def log_malformed_project_payload
      payload_keys = ["id", "name", "path", "path_with_namespace", "namespace"]
      payload_snippet = if project.is_a?(Hash) || (project.respond_to?(:slice) && project.respond_to?(:to_h))
                          begin
                            project.slice(*payload_keys)
                          rescue ArgumentError, TypeError, NoMethodError
                            # Fallback if slice doesn't work as expected
                            begin
                              project.to_h.select { |k, _| payload_keys.include?(k) }
                            rescue StandardError
                              { error: "unable to slice project payload", type: project.class.name, value: project.to_s[0..199] }
                            end
                          end
                        else
                          { error: "project is not a Hash", type: project.class.name, value: project.to_s[0..199] }
                        end
      current_export.output_logger.error(
        "Malformed project payload received from GitLab: #{payload_snippet.inspect}"
     )
    end

    # Exports the user performing the export
    def export_authenticated_user
      @authenticated_user ||= export_user(Gitlab.user)
    end

    # Serialize and export a GitLab Group as a GitHub Organization. Also exports
    # the group members and their group memberships
    #
    # @param [Hash] owner the GitLab group to be exported
    def export_group(owner)
      owner["members"] = Gitlab.group_members(Gitlab.api_v3? ? owner["path"] : owner["full_path"])
      serialize "organization", owner
      team_builder.add_project(
        model_url_service.url_for_model(owner),
        model_url_service.url_for_model(project)
      )
      owner["members"].map do |member|
        # Get the permission level for this member
        permission = team_access(
          member["access_level"],
          member_username: member["username"],
          resource_name: owner["full_path"] || owner["path"]
        )

        # Only add member to team if we have a valid permission
        if permission
          team_builder.add_member(
            model_url_service.url_for_model(owner),
            model_url_service.url_for_model(member),
            permission
          )
        else
          # Log warning when skipping a member due to invalid permission
          current_export.output_logger.warn(
            "Skipping team membership for '#{member['username']}' in '#{owner['full_path'] || owner['path']}' " \
            "due to invalid access level #{member['access_level']}"
          )
        end

        # Each org member needs an associated user created
        export_user(member["username"])
      end
    end

    # Serialize and export the project collaborators
    #
    # @return [Array] the GitLab project collaborators
    def export_collaborators
      Gitlab.project_team_members(project["id"]).select do |collaborator|
        access_level = collaborator["access_level"]
        if PERMISSION_MAP[access_level].nil?
          current_export.output_logger.warn(
            "Unknown access level #{access_level} for user '#{collaborator['username']}' in project " \
            "'#{project_name}'. This collaborator will be skipped."
          )
          false
        else
          export_user(collaborator["username"])
          true
        end
      end
    end

    # Prepare the Commit comments for @project to be exported
    def prepare_commit_comments_for_export
      current_export.output_logger.info "Collecting data for commit comments..."
      Gitlab.commits(project["id"]).each do |commit|
        Gitlab.commit_comments(project["id"], commit["id"]).each do |commit_comment|
          prepare_commit_comment_for_export(commit, commit_comment)
        end
      end
    end

    # Prepare a GitLab Commit comment to be exported
    #
    # @param [Hash] commit the parent GitLab Commit of the Commit comment to be exported
    # @param [Hash] commit_comment the GitLab Commit comment to be exported
    def prepare_commit_comment_for_export(commit, commit_comment)
      commit_comments.push(
        CommitCommentExporter.new(commit, commit_comment, project_exporter: self)
      )
    end

    # Serialize and export the milestones for @project
    def export_milestones
      return unless project["issues_enabled"] || project["merge_requests_enabled"]

      current_export.output_logger.info "Exporting milestones..."
      milestone_titles = []
      Gitlab.milestones(project["id"]).each do |m|
        i = 0
        new_title = m["title"]
        while milestone_titles.include?(new_title)
          i += 1
          new_title = "#{m['title']} (#{i})"
        end
        milestone_titles << new_title
        m["title"] = new_title
      end.each(&method(:export_milestone))
    end

    # Serialize and export a GitLab Milestone
    #
    # @param [Hash] milestone the GitLab milestone to be exported
    def export_milestone(milestone)
      milestone["repository"] = project
      milestone["user"] = Gitlab.user
      serialize("milestone", milestone)
    end

    # Serialize and export the protected branches for @project
    def export_protected_branches
      current_export.output_logger.info "Exporting protected branches..."
      Gitlab.branches(project["id"]).each do |branch|
        next unless branch["protected"]

        export_protected_branch(branch)
      end
    end

    # Serialize and export a GitLab protected branch
    #
    # @param [Hash] protected_branch the GitLab Protected Branch to be exported
    def export_protected_branch(protected_branch)
      ProtectedBranchExporter.new(
        protected_branch,
        project_exporter: self
      ).export
    end

    # Attach GitLab hooks to @project to be serialized
    def export_hooks
      project["webhooks"] = Gitlab.webhooks(project["id"])
    end

    # Prepare the Issues for @project to be exported
    def prepare_issues_for_export
      return unless project["issues_enabled"]

      current_export.output_logger.info "Collecting data for issues and comments..."
      Gitlab.issues(project["id"]).each(&method(:prepare_issue_for_export))
    end

    # Prepare a GitLab Issue to be exported
    #
    # @param [Hash] issue the GitLab Issue to be exported
    def prepare_issue_for_export(issue)
      issues.push(
        IssueExporter.new(issue, project_exporter: self)
      )
    end

    # Prepare the Merge Requests for @project to be exported
    def prepare_merge_requests_for_export
      return unless project["merge_requests_enabled"]

      current_export.output_logger.info "Collecting data for merge requests and comments..."
      Gitlab.merge_requests(project["id"]).each(&method(:prepare_merge_request_for_export))
    end

    # Prepare a GitLab Merge Request to be exported
    #
    # @param [Hash] merge_request the GitLab Merge Request to be exported
    def prepare_merge_request_for_export(merge_request)
      merge_requests.push(
        MergeRequestExporter.new(merge_request,
                                 project_exporter: self,
                                 project_owner: project_owner)
      )
    end

    alias export_issues prepare_issues_for_export
    alias export_merge_requests prepare_merge_requests_for_export
    alias export_commit_comments prepare_commit_comments_for_export

    # Serialize and export the GitLab tags for @project as GitHub Releases
    def export_tags
      current_export.output_logger.info "Exporting tags..."
      Gitlab.tags(project["id"]).each do |tag|
        export_tag(tag) if tag["release"]
      end
    end

    # Serialize and export a GitLab tag
    #
    # @param [Hash] tag the GitLab tag to be exported
    def export_tag(tag)
      tag["repository"] = project
      tag["user"] = Gitlab.user # attribute all tags to export user
      serialize("release", tag)
    end

    def export_wiki
      return unless project["wiki_enabled"]

      current_export.output_logger.info "Cloning project wiki..."
      archiver.clone_wiki(project)
    end

    # Goes through the stored Issues and Pull requests to rewrite their ids
    # sequentially, then rewrites the mentions to them in Pull Requests, Issues,
    # and comments
    #
    # @param [Symbol, NilClass] skip the model that will not be renumbered
    def renumber_issues_and_merge_requests(skip: nil)
      current_export.output_logger.info "Renumbering issues and merge requests chronologically..."
      index, models = case skip
                      when :issues
                        [
                          issues.map { |issue| issue.model["iid"] }.max.to_i + 1,
                          merge_requests
                        ]
                      when :merge_requests
                        [
                          merge_requests.map { |merge_request| merge_request.model["iid"] }.max.to_i + 1,
                          issues
                        ]
                      else
                        [
                          1,
                          [issues, merge_requests].flatten
                        ]
                      end
      models.sort_by(&:created_at).each.with_index(index) do |m, i|
        m.renumber!(i)
      end
      (issues + merge_requests).each(&:rewrite!)
    end

    # Goes through the stored Commit Comments and rewrites references to Issues
    # and Merge requests to newly renumbered Issues and Pull Requests
    def rewrite_commit_comment_references_to_issues_and_merge_requests
      current_export.output_logger.info "Rewriting issues and merge requests references in commit comments..."
      models = [commit_comments].flatten.sort_by(&:created_at)
      models.each(&:rewrite!)
    end

    # For a given owner name, determine if it is a user or group and send back
    # complete information about the owner
    #
    # @param [String] name the name of the owner
    # @return [Array] an Array containing the kind of owner and information
    #   about that owner
    def get_owner_and_kind(name)
      if user = Gitlab.user_by_username(name)
        [user, "user"]
      elsif group = Gitlab.group(name)
        [group, "group"]
      else
        raise NoNamespaceFound, name
      end
    end

    # MINIMAL   = 5  (upgraded to GUEST)
    # GUEST     = 10
    # PLANNER   = 15 (downgraded to GUEST)
    # REPORTER  = 20
    # DEVELOPER = 30
    # MASTER    = 40
    # OWNER     = 50
    PERMISSION_MAP = {
      5 => "read", # Minimal access -> Guest (upgraded)
      10 => "read",
      15 => "read", # Planner -> Guest (downgraded)
      20 => "triage",
      30 => "write",
      40 => "maintain",
      50 => "admin"
    }

    private

    # Maps GitLab access levels to GitHub permissions, adjusting unsupported levels
    #
    # @param [Integer] access_level the GitLab access level
    # @param [String] member_username the username of the member (for logging)
    # @param [String] resource_name the name of the resource (repo/group) (for logging)
    # @return [String, nil] the GitHub permission level, or nil if the access level is not recognized
    def team_access(access_level, member_username: nil, resource_name: nil)
      permission = PERMISSION_MAP[access_level]

      # Log warning for adjusted access levels
      if access_level == 5
        # Minimal -> Guest is an upgrade (gaining more permissions)
        current_export.output_logger.warn(
          "Upgrading access level for member '#{member_username}' in '#{resource_name}': " \
          "Minimal access (5) -> Guest (10) (permission: #{permission})"
        )
      elsif access_level == 15
        # Planner -> Guest is a downgrade (losing issue/epic management permissions)
        current_export.output_logger.warn(
          "Downgrading access level for member '#{member_username}' in '#{resource_name}': " \
          "Planner (15) -> Guest (10) (permission: #{permission})"
        )
      elsif permission.nil?
        # Log warning for completely unmapped access levels
        current_export.output_logger.warn(
          "Unknown access level #{access_level} for member '#{member_username}' in '#{resource_name}'. " \
          "This member will be skipped."
        )
      end

      permission
    end

    class NoNamespaceFound < StandardError
      def initialize(namespace)
        @namespace = namespace
      end

      def message
        "Namespace with name `#{@namespace}` not found"
      end
    end

    class MissingNamespaceError < StandardError
      def initialize(project, retry_count)
        @project = project
        @retry_count = retry_count
      end

      def message
        payload_snippet = @project.slice("id", "name", "path", "path_with_namespace", "namespace")
        "GitLab returned project without namespace field after #{@retry_count} retry attempts. " \
        "Project: #{payload_snippet.inspect}"
      end
    end
  end
end
