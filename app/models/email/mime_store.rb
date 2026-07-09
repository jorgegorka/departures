class Email::MimeStore
  class << self
    def write(email, eml)
      absolute_path = root.join(relative_path(email))
      FileUtils.mkdir_p(absolute_path.dirname)
      File.binwrite(absolute_path, eml)
      email.update!(mime_path: relative_path(email), mime_size: eml.bytesize)
    end

    def read(email)
      File.binread(root.join(email.mime_path))
    end

    def delete(email)
      if email.mime_path.present?
        FileUtils.rm_f(root.join(email.mime_path))
      end
    end

    def root
      # config.x.<unset> returns a truthy empty OrderedOptions (not nil), so guard
      # with presence — otherwise the || fallback never fires outside the test env.
      configured = Rails.application.config.x.mime_store_root
      Pathname(configured.presence || Rails.root.join("storage", "emails"))
    end

    private
      def relative_path(email)
        File.join(email.project_id.to_s, "#{email.public_id}.eml")
      end
  end
end
