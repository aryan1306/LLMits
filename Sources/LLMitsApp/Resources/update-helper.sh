#!/bin/sh
set -eu

staged_app=$1
target_app=$2
parent_pid=$3

case "$staged_app:$target_app" in
    */LLMits.app:*/LLMits.app) ;;
    *) exit 1 ;;
esac

backup_app="${target_app}.previous-${parent_pid}"
if [ -e "$backup_app" ]; then exit 1; fi

restore_if_needed() {
    if [ -e "$backup_app" ] && [ ! -e "$target_app" ]; then
        /bin/mv "$backup_app" "$target_app"
        /usr/bin/open "$target_app"
    fi
}
trap restore_if_needed EXIT

attempt=0
while /bin/kill -0 "$parent_pid" 2>/dev/null; do
    if [ "$attempt" -ge 240 ]; then exit 1; fi
    /bin/sleep 0.25
    attempt=$((attempt + 1))
done

if ! /bin/mv "$target_app" "$backup_app"; then
    /usr/bin/open "$target_app"
    exit 1
fi
if ! /bin/mv "$staged_app" "$target_app"; then
    /bin/mv "$backup_app" "$target_app"
    /usr/bin/open "$target_app"
    exit 1
fi

if ! /usr/bin/open "$target_app"; then
    /bin/mv "$target_app" "$staged_app"
    /bin/mv "$backup_app" "$target_app"
    /usr/bin/open "$target_app"
    exit 1
fi

/bin/rm -rf "$backup_app"
/bin/rm -rf "$(/usr/bin/dirname "$staged_app")"
