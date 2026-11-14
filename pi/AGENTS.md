# Global agent notes

## rtk condenses bash output

Bash calls may be rewritten to `rtk` wrappers, so output is condensed, not
complete: a clipped result ends with `[+N hidden: rtk recall <hash>]` ->
`rtk recall <hash> --full` before acting on the listing, deletions included.
Blame rtk only when its name is in the error; `env RTK_DISABLED=1 <cmd>`.
