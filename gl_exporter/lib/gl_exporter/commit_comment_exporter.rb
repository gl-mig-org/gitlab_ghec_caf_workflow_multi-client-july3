# frozen_string_literal: true
class GlExporter
  class CommitCommentExporter
    include UserContentRewritable
    include Writable
    include Authorable
    include Attachable

    attr_reader :commit, :commit_comment, :project_exporter, :archiver

    def initialize(commit, commit_comment, project_exporter:)
      normalized_commit_comment = normalize_commit_comment(commit_comment)
      @commit_comment = normalized_commit_comment
      @project_exporter = project_exporter
      @archiver = current_export.archiver
      normalized_commit_comment["commit"] = commit
      normalized_commit_comment["repository"] = project
      normalized_commit_comment["author"] && export_user(normalized_commit_comment["author"]["username"])
    end

    # Alias for `commit_comment`
    #
    # @return [Hash]
    def model
      commit_comment
    end

    # References the project for the export
    #
    # @return [Hash]
    def project
      project_exporter.project
    end

    # References the current export
    #
    # @return [GlExporter]
    def current_export
      project_exporter.current_export
    end

    # Accessor for the model's created timestamp
    #
    # @return [String]
    def created_at
      commit_comment["created_at"]
    end

    # Instruct the exporter to rewrite the user content for the `commit_comment`
    def rewrite!
      rewrite_user_content!
    end

    # Instruct the exporter to export the `commit_comment`.
    def export
      extract_attachments("commit_comment", commit_comment)
      serialize("commit_comment", commit_comment)
    end

    # Normalize commit comment when it is a string
    def normalize_commit_comment(raw)
      return raw if raw.is_a?(Hash)
      return JSON.parse(raw) if raw.is_a?(String)

      logger.error "Commit comment not JSON; surfacing comment #{raw}"
      raise ArgumentError, "Commit comment not JSON: #{raw}"
    rescue JSON::ParserError
      logger.error "Commit comment not JSON; surfacing comment #{raw}"
      raise ArgumentError, "Commit comment not JSON: #{raw}"
    end
  end
end
