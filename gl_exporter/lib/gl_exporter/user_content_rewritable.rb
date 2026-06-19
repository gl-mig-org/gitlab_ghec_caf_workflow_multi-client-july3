# frozen_string_literal: true
class GlExporter
  module UserContentRewritable
    ISSUE_MR_REGEX = /([^\w])([#|!])(\d+)/

    # Matches a Kramdown Inline Attribute List (IAL) attached to an inline image,
    # e.g. `![alt](/uploads/abc/x.png){width=900 height=522}`. GitLab's editor
    # appends this block when an image is resized/pasted, but GitHub Flavored
    # Markdown does not understand it, so the literal `{...}` would otherwise
    # render as visible text next to the image. Capture group 1 is the image
    # markdown itself, which is preserved while the trailing IAL is dropped.
    #
    # Matches (capture group 1 shown in brackets, replacement keeps just it):
    #   "![a](/uploads/x.png){width=900}"  => ["![a](/uploads/x.png)"]
    #   "![](/uploads/x.png) {.foo #bar}"  => ["![](/uploads/x.png)"]  (optional space/tab)
    # Does not match (left untouched):
    #   "![a](/uploads/x.png)"             (no trailing {...})
    #   "[a](/uploads/x.png){width=900}"   (a link, not an image: no leading !)
    #   "text {standalone braces}"         (no image markdown immediately before)
    KRAMDOWN_IAL_REGEX = /(!\[(?>[^\]\[\n]*)\]\((?>[^)\s]*)\))[ \t]*\{(?>[^}\n]+)\}/

    # Detects the hash key for `model`'s content body and rewrites that content
    def rewrite_user_content!
      body_key = ["body", "note", "description"].detect { |x| model[x] }
      rewrite_numeric_mentions(body_key)
      rewrite_kramdown_image_attributes(body_key)
    end

    # Strips Kramdown Inline Attribute Lists that follow inline images so the
    # migrated GitHub content does not show the literal `{width=... height=...}`
    # markup. The image link itself is left untouched.
    #
    # @param [String] body_key since content bodies have various attribute names,
    #   pass in the name for that attribute
    def rewrite_kramdown_image_attributes(body_key)
      return unless body_key

      model[body_key] = model[body_key].to_s.gsub(KRAMDOWN_IAL_REGEX, '\1')
    end

    # Rewrites mentions in content bodies to Issues and Pull Requests that use
    # `#n` or `!n`
    #
    # @param [String] body_key since content bodies have various attribute names,
    #   pass in the name for that attribute
    def rewrite_numeric_mentions(body_key)
      model[body_key] = model[body_key].to_s.gsub(ISSUE_MR_REGEX) do |match|
        "#{$1}##{translate_id($2, $3)}"
      end
    end

    # For a given issue or merge_request id, return the new rewritten id
    #
    # @param [String] indicator `!` or `#` to determine if we are getting the id
    #   for a merge request or issue
    # @param [Integer,String] old_id the id before it was rewritten
    # @return [Integer] the rewritten id
    def translate_id(indicator, old_id)
      model_name = (indicator == "!") ? :merge_requests : :issues
      new_id = project_exporter.rewritten_ids[model_name][old_id.to_i]
      (new_id || old_id).to_s
    end
  end
end
