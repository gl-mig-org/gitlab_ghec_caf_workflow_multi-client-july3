# frozen_string_literal: true
class GlExporter
  # @todo Update to use UrlTemplates.
  class ModelUrlService

    # Gets a GitLab style URL for a GitLab model. Used to explicitly identify a
    # model.
    #
    # @param [Hash] model a GitLab model
    # @param [Hash] opts
    # @option opts [String] :type the type of model being passed in; uses GitHub
    #   naming conventions
    # @return [String] the url for the model
    def url_for_model(model, opts = {})
      return unless model

      case opts[:type]
      when "label"
        "#{url_for_model(model["repository"])}/labels#/#{parameterize(model["name"])}"
      when "issue"
        "#{url_for_model(model["repository"])}/issues/#{model["iid"]}"
      when "protected_branch"
        "#{url_for_model(model["repository"])}/protected_branches/#{model["name"]}"
      when "issue_comment"
        if model.has_key?("issue")
          "#{url_for_model(model["issue"], type: "issue")}#note_#{model["id"]}"
        else
          "#{url_for_model(model["merge_request"], type: "pull_request")}#note_#{model["id"]}"
        end
      when "pull_request"
        "#{url_for_model(model["repository"])}/merge_requests/#{model["iid"]}"
      when "commit_comment"
        "#{url_for_model(model["repository"])}/commit/#{model["commit"]["id"]}#note_#{fake_id(model)}"
      when "milestone"
        "#{url_for_model(model["repository"])}/milestones/#{model["iid"]}"
      when "release"
        "#{url_for_model(model["repository"])}/tags/#{parameterize(model["name"])}"
      when "attachment"
        File.join(url_for_model(model["repository"]), model["attach_path"])
      when "team"
        group = model["group"]
        group[%r{(http.+/groups/)(.+)}, 1] + group[%r{(http.+/groups/)(.+)}, 2].gsub("/", "-") + "/teams/" + model["name"].parameterize
      else
        # If web_url is a groups url with subgroups, we convert the slashes between the groups to dashes
        # so that the GitHub Importer can parse the url correctly
        if !Gitlab.api_v3? && (/http.+\/groups\//.match?(model["web_url"]))
          # pp model
          model["web_url"][%r{(http.+/groups/)}] + convert_slash_to_dash(model["full_path"])
        # If the model is a repository we can get the full_path of the namespace which includes the parent groups
        elsif !Gitlab.api_v3? && model["namespace"] && model["namespace"]["full_path"]
          model["web_url"].sub(model["namespace"]["full_path"], convert_slash_to_dash(model["namespace"]["full_path"]))
        else
          model["web_url"]
        end
      end
    end

    # Builds the authenticated project-uploads API URL that serves an upload's
    # bytes under PRIVATE-TOKEN on GitLab >= 17.4:
    #   GET <api_endpoint>/projects/<id>/uploads/<secret>/<filename>
    #
    # attach_path is "/uploads/<secret>/<filename>", e.g.
    #   "/uploads/aca2cc60c183e113481adbdd167aa9fe/pdf-sample.pdf"
    #   => "<api_endpoint>/projects/<id>/uploads/aca2cc60c183e113481adbdd167aa9fe/pdf-sample.pdf"
    # Returns nil when there is no numeric project id, or when attach_path is not
    # "/uploads/<secret>/<filename>", so the caller can fall back to the web URL.
    #
    # @param [Hash] project a GitLab project model
    # @param [String] attach_path the inline "/uploads/..." path
    # @return [String, nil]
    def upload_api_url(project, attach_path)
      return unless project && project["id"]

      upload = attach_path.to_s.match(%r{\A/uploads/(?<secret>[^/]+)/(?<filename>.+)\z})
      return unless upload

      File.join(
        Gitlab.api_endpoint.to_s.chomp("/"),
        "projects",
        project["id"].to_s,
        "uploads",
        upload[:secret],
        upload[:filename]
      )
    end

    private

    # Sometimes GitLab doesn't send over IDs for resources, so we make them up.
    #
    # IMPORTANT: this must be stable across body mutations. Attachable rewrites
    # the model's body ("note"/"body"/"description") in-place when it extracts
    # inline /uploads/... links. If we hashed those fields, the URL computed
    # inside the gsub block (parent_url for the attachment record) would differ
    # from the URL computed later by Writable#serialize for the parent itself,
    # leaving every commit-comment attachment orphaned.
    BODY_KEYS_EXCLUDED_FROM_FAKE_ID = %w[note body description].freeze

    def fake_id(model)
      nonrewritten_properties = model.reject { |k, _| BODY_KEYS_EXCLUDED_FROM_FAKE_ID.include?(k) }
      md5 = Digest::MD5.new # rubocop:disable GitHub/InsecureHashAlgorithm
      md5 << nonrewritten_properties.to_s
      md5.hexdigest
    end

    def parameterize(str)
      URI.encode_www_form_component(str)
    end

    # GitHub Importer expects organization names without "/",
    # for support of subgroups we replace "/" with "-"
    def convert_slash_to_dash(str)
      str.gsub("/", "-")
    end
  end
end
