module Pakyow
  module Helpers
    def mailer(view_path)
      Mailer.new(view_path, @presenter.view_store)
    end
  end
end
