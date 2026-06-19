# frozen_string_literal: true
class GlExporter
  module Attachable
    ATTACHMENT_REGEX = /\[(?<link_text>[^\]\n\r]*?)\]\((?<attach_path>\/uploads\/[^)\s]+?)\)/

    def model_url_service
      @model_url_service ||= ModelUrlService.new
    end

    # Scan user content for inline attachments, serialize those attachments, and
    # update the user content to reflect the new URL.
    #
    # @param [String] type the model type we are extracting attachments from
    # @param [Hash] model the model we are extracting attachments from
    def extract_attachments(type, model)
      body_key = ["body", "note", "description"].detect { |x| model[x] }
      model[body_key] = model[body_key].to_s.gsub(ATTACHMENT_REGEX) do
        match = $~
        attach_path = match[:attach_path].to_s.gsub("\\", "")
        archive_path = build_archive_attach_path(attach_path)
        download_url = attachment_download_url(project, attach_path)
        tmp_model = {
          "type"         => type,
          "model"        => model,
          "repository"   => project,
          "attach_path"  => attach_path,
          "archive_path" => archive_path,
        }
        attach_url = model_url_service.url_for_model(tmp_model, type: "attachment")
        parent_url = model_url_service.url_for_model(model, type: type)

        begin
          # When save_attachment returns false (e.g. bad URL, transient HTTP
          # failure) preserve the original markdown so the migrated content
          # still shows the link text and a human can investigate. A bare
          # `next` would make gsub coerce nil into "" and silently strip the
          # entire `[text](/uploads/...)` from the body.
          next match.to_s unless archiver.save_attachment(archive_path, download_url, parent_url)
          serialize("attachment", tmp_model)
          "[#{match[:link_text]}](#{attach_url})"
        rescue => e
          # Log error and continue with original attachment reference if extraction fails
          begin
            model_identifier = model["iid"] || model["id"] || "unknown"
            model_title = model["title"] || model["name"] || "untitled"
            project_name = project["path_with_namespace"] || project["name"] || "unknown project"

            error_context = "Failed to extract attachment in #{type} ##{model_identifier} ('#{model_title}') " \
                          "in project '#{project_name}'. " \
                          "Attachment path: '#{attach_path}', " \
                          "Generated URL: '#{attach_url}'. " \
                          "Error: #{e.message}. " \
                          "You might want to fix the attachment reference at the source and then run the export again."

            [current_export.logger, current_export.output_logger].each do |logger|
              logger.error error_context
            end
          rescue => logging_error
            # Fallback if logging fails - at least don't crash the export
            puts "ERROR: Could not extract attachment from '#{attach_path}': #{e.message}"
            puts "WARNING: Logging also failed: #{logging_error.message}"
          end
          match.to_s  # Return original match text
        end
      end
    end

    private

    # Build a tarball-relative path that is unique per occurrence by prefixing
    # the filename with a monotonically increasing counter. This prevents the
    # importer from deleting/overwriting the same blob when one upload is
    # referenced from multiple places (e.g. issue body + comment).
    #
    # The counter deliberately lives on the archiver rather than here: Attachable
    # is mixed into many per-model exporters (issue, merge request, notes,
    # commit comment, ...), but they all share the one ArchiveBuilder instance
    # from `current_export.archiver`. Only a counter owned by that single shared
    # sink stays unique across every body in the tarball; a counter local to
    # Attachable would reset for each exporter and collide across them.
    #
    # Example: "/uploads/abcd/image.png" + counter 7 => "/uploads/abcd/7_image.png"
    def build_archive_attach_path(attach_path)
      counter = archiver.next_attachment_counter
      dir = File.dirname(attach_path)
      base = File.basename(attach_path)
      File.join(dir, "#{counter}_#{base}")
    end

    # Build the download URL for a project upload.
    #
    # On GitLab >= 17.4 the project Markdown uploads download API
    # (`GET /api/v4/projects/<id>/uploads/<secret>/<filename>`) accepts a
    # PRIVATE-TOKEN and serves the file directly. It is the only documented
    # path that works for non-image attachments on private projects, where the
    # web URL `<repo>/uploads/...` redirects token-authenticated callers to the
    # sign-in page.
    #
    # Falls back to the legacy web URL when the instance is too old to expose
    # the API endpoint (the secret+filename form first appears in 17.4), when
    # we lack the numeric project id needed to build the API URL, or when the
    # captured attach_path doesn't have the `/uploads/<secret>/<filename>`
    # shape the API requires. The fallback works for public projects and for
    # image attachments on private projects under GitLab's default settings.
    def attachment_download_url(project, attach_path)
      if Gitlab.project_uploads_api_available?
        api_url = model_url_service.upload_api_url(project, attach_path)
        return api_url if api_url
      end

      File.join(model_url_service.url_for_model(project), attach_path)
    end
  end
end
