# Global agent notes

## rtk condenses bash output

Bash calls may be rewritten to `rtk` wrappers, so output is condensed, not
complete: a clipped result ends with `[+N hidden: rtk recall <hash>]` ->
`rtk recall <hash> --full` before acting on the listing, deletions included.
Blame rtk only when its name is in the error; `env RTK_DISABLED=1 <cmd>`.

## Evidence beats recall

Verify what the answer depends on, with a tool: read the file, run the command,
check the installed version before stating what a flag or API expects. Cite the
source (path and line, or command and output) so a wrong answer is checkable
rather than merely confident, and recall a clipped rtk listing before quoting
it. Absence of a signal is not a signal: a timeout, an empty diagnostic cache,
or a skipped check is its own state, never a pass.

`done`, `fixed`, `works` are claims, not results. Carry the check that could
have failed, and prefer one that cannot share your reasoning (a test, a
compiler, a fresh read of the source) over rereading what you already believe.
A green build only proves the code compiles; a command that cannot fail proves
nothing. Where no such check exists, or it costs more than the answer is worth,
say "unchecked" and name the check you did not run.
