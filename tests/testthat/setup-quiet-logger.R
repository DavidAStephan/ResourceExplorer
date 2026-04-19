## Stable logger for the test run.
##
## Several tests spin up a `withr::local_tempdir()` and call
## `init_logger()` with a tempdir-based path. Once the tempdir is
## cleaned up, subsequent `log_warn()`/`log_info()` calls can fail
## when the file appender tries to write to the now-missing path.
##
## This setup installs a stdout appender at ERROR threshold so tests
## are quiet by default. Individual tests that call `init_logger()`
## will override it; after those tests unwind we restore.

logger::log_threshold(logger::FATAL, namespace = "resourcetracker")
logger::log_appender(logger::appender_stdout,
                     namespace = "resourcetracker")
