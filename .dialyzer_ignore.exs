# Known dialyzer false positives.
#
# Mix.shell/0, Mix.Task.run/1, and Mix.Task callback info are not in the PLT
# because :mix is a dev/test dependency and not included in the production PLT.
# These are standard Mix task APIs and not real issues.
[
  {"lib/mix/tasks/phx_media_library.clean.ex", :callback_info_missing},
  {"lib/mix/tasks/phx_media_library.clean.ex", :unknown_function},
  {"lib/mix/tasks/phx_media_library.gen.migration.ex", :callback_info_missing},
  {"lib/mix/tasks/phx_media_library.gen.migration.ex", :unknown_function},
  {"lib/mix/tasks/phx_media_library.install.ex", :callback_info_missing},
  {"lib/mix/tasks/phx_media_library.install.ex", :unknown_function},
  {"lib/mix/tasks/phx_media_library.regenerate.ex", :callback_info_missing},
  {"lib/mix/tasks/phx_media_library.regenerate.ex", :unknown_function},
  {"lib/mix/tasks/phx_media_library.regenerate_responsive.ex", :callback_info_missing},
  {"lib/mix/tasks/phx_media_library.regenerate_responsive.ex", :unknown_function}
]
