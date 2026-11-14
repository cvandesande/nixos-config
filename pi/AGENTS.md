# Global agent notes

## rtk condenses bash output

Bash calls may be rewritten to `rtk` wrappers, so output is condensed, not
complete: a clipped result ends with `[+N hidden: rtk recall <hash>]` ->
`rtk recall <hash> --full` before concluding absence. If a command fails
mentioning rtk, rerun it with `RTK_DISABLED=1`.
