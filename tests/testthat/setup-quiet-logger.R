## Stable logger for the test run.
##
## The base-R logger writes to a dated file under cfg$paths$logs. Tests
## that spin up a `withr::local_tempdir()` and call `init_logger()` on
## that tempdir can leave the global state pointing at a path that
## disappears when the tempdir unwinds. We pin the session threshold to
## ERROR and aim it at the testthat tempdir (persisted for the whole
## test session) so straggling log calls stay harmless.

.session_log_dir <- tempfile("rt_test_logs_")
dir.create(.session_log_dir, showWarnings = FALSE, recursive = TRUE)
init_logger(list(paths = list(logs = .session_log_dir),
                 logging = list(level = "ERROR")))
