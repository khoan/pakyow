Pakyow::App.define do
  configure(:test) do
    app.src_dir = 'test/support/lib'
    presenter.view_stores[:test] = "test/support/views"
  end
end
