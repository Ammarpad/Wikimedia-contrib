#!/bin/bash
#
# Emails a summary of errors logged to `error.log` in the last 24 hours.
#
# This reads `~/error.log` and the most recent rotated `~/logs/error.log-*` backup, groups similar
# messages, and sends an email with the top 10.
#
set -euo pipefail

##########
## Configure
##########
hours=24       # number of hours to scan back from the job run date
top_count=10   # number of most common messages to list in the email
max_length=300 # max length of each log message to compare and show

smtp_url="smtp://mail.tools.wmcloud.org:25"
toolName=$(basename "$HOME")
address="tools.$toolName@toolforge.org"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT


##########
## Find error logs
##########
# check latest + rotated logs, since error log may have been rotated recently
logs=()
if [ -f "$HOME/error.log" ]; then
    logs+=("$HOME/error.log")
fi
newestPath=$(ls -1t "$HOME/logs/"error.log-* 2>/dev/null | head -1 || true)
if [ -n "$newestPath" ]; then
    logs+=("$newestPath")
fi

if [ ${#logs[@]} -eq 0 ]; then
    echo "no logs found; nothing to report"
    exit 0
fi


##########
## Collect normalized errors
##########
cutoff=$(date -u -d "$hours hours ago" '+%Y-%m-%d %H:%M:%S')
now=$(date -u '+%Y-%m-%d %H:%M:%S')

# extract first lines of each error in range into $work/entries
# (`zcat -f` reads each log whether or not it's been compressed)
zcat -f -- "${logs[@]}" 2>/dev/null |
    # grab first line with the timestamp
    grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}: ' |

    # drop messages before the cutoff
    awk -v cutoff="$cutoff" 'substr($0, 1, 19) >= cutoff' > "$work/entries" || true

# drop unneeded log messages, normalize non-deterministic patterns, and sort into $work/counted
sed "
    # These patterns are based on the Lighttpd error log format, which has two forms:
    # Lighttpd message: \`2026-09-03 01:17:12: (configfile.c.1289) WARNING: unknown config-key: server.dir-listing (ignored)\`
    # PHP message:      \`2026-09-03 04:58:28: (mod_fastcgi.c.449) FastCGI-stderr:PHP Fatal error:  Uncaught Error: Call to ...\`

    # strip log timestamp
    s/^[0-9-]* [0-9:]*: //

    # strip source file/line like '(mod_fastcgi.c.449)'
    s/^([^)]*) //

    # strip 'FastCGI-stderr:' marker for PHP errors
    s/^FastCGI-stderr://

    # strip session key added by Logger::error
    s/^\[[0-9a-f]*\] //
    s:/\*[0-9a-f]*\*/:/*key*/:g

    # strip quoted values, like literals in a SQL query
    s/'[^']*'/'?'/g
    s/\"[^\"]*\"/\"?\"/g

    # strip process IDs, timestamps, row IDs, etc
    s/[0-9]\{4,\}/N/g
" "$work/entries" |
    # drop routine lifecycle messages (not errors)
    grep -vE 'logfiles cycled|server started|server stopped|unknown config-key' |

    # drop lines which just continue the preceding error
    grep -vE '^(#[0-9]+ |Stack trace:|[[:space:]]*thrown in )' |

    # grab the top messages
    cut -c "1-$max_length" |
    sort |
    uniq -c |
    sort -rn > "$work/counted" || true

if [ ! -s "$work/counted" ]; then
    echo "no errors logged; nothing to report"
    exit 0
fi


##########
## Build the summary
##########
total=$(awk '{ sum += $1 } END { print sum + 0 }' "$work/counted")
unique=$(wc -l < "$work/counted")
head -n "$top_count" "$work/counted" > "$work/top"

{
    echo "$total errors ($unique unique) logged by the $toolName tool between $cutoff and $now UTC."
    echo
    echo "Most common errors:"
    echo
    awk '{ count = $1; sub(/^ *[0-9]+ /, ""); printf "%7d x %s\n", count, $0 }' "$work/top" # "$count x $message"
    echo
    echo "See ~/error.log and ~/logs/error.log-* on the server for the full error info."
} > "$work/body"

cat "$work/body"


##########
## Build the email
##########
{
    echo "From: $address"
    echo "To: $address"
    echo "Subject: [$toolName] New errors logged in the last $hours hours"
    echo "MIME-Version: 1.0"
    echo "Content-Type: text/plain; charset=utf-8"
    echo "Content-Transfer-Encoding: 8bit"
    echo
    cat "$work/body"
} | sed 's/$/\r/' > "$work/message" # SMTP needs CRLF line endings


##########
## Send the email
##########
if ! curl --silent --show-error --url "$smtp_url" --mail-from "$address" --mail-rcpt "$address" --upload-file "$work/message"; then
    echo "could not send the email report" >&2
    exit 1 # job's `emails: onfailure` will send a notification
fi
