require "./arr_janitor"

# Application entrypoint. Kept out of `src/arr_janitor/` (and out of the
# `arr_janitor.cr` library file) so specs can `require "../src/arr_janitor"`
# without executing the app.
ArrJanitor::CLI.run(ARGV)
