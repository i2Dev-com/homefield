#!/usr/bin/env bash
# The runner's job-completed hook (ACTIONS_RUNNER_HOOK_JOB_COMPLETED), run as
# runner. The runner picks the interpreter by extension, so the hook needs
# ".sh"; the cleanup itself runs as root, like the job-started hook's script.
exec sudo -n /usr/local/sbin/homefield-job-cleanup