# Global agent notes

## rtk condenses some bash output (pi-rtk-optimizer rewrites the commands)

A `bash` tool call may be rewritten to its `rtk` equivalent (`cat` -> `rtk read`,
`ls` -> `rtk ls`, `git` -> `rtk git`), which shortens output to save tokens.
`grep`, `rg` and `find` are excluded in `~/.config/rtk/config.toml` and run raw.

- Shorter output is not complete output. When a filter trims a long or failing
  result, rtk prints `[full output: rtk recall <hash>]`; read the elided part
  back with `rtk recall <hash> --full` (or `--grep PAT`, `--list` to browse)
  before concluding that an entry or line is absent.
- If output looks garbled, or an error mentions an rtk subcommand or clap
  usage, rerun the same command with `RTK_DISABLED=1` in front of it, or as
  `rtk bypass <cmd>` (runs raw, savings still tracked). Do not conclude the
  command itself is broken.
- Result counts can be capped by `limits.grep_max_results` and
  `grep_max_per_file`.
- Rewriting is the extension's job, not yours: keep typing plain commands, and
  use `rtk gain` to see what it saved.
