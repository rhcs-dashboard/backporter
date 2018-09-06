#!/bin/bash
set -euo pipefail
(( $BASH_VERSINFO >= 4 )) || { echo "ERROR: Bash 4 or above required" 1>&2; exit 1; }

export GIT_PAGER=""


readonly CFGDIR="$HOME/.backporter"
readonly COMMIT_MESSAGE_PATTERNS_FILE="$CFGDIR/commit_message_patterns.txt"
readonly DIR_PATTERNS_FILE="$CFGDIR/dir_patterns.txt"
readonly AUTHOR_EMAILS_FILE="$CFGDIR/author_emails.txt"
readonly COMMIT_CACHE_DIR="$CFGDIR/commits"

readonly C_RED=`tput setaf 1`
readonly C_GREEN=`tput setaf 2`
readonly C_YELLOW=`tput setaf 3`
readonly C_NC=`tput sgr0`
readonly C_BOLD=`tput bold`
readonly C_DIM=`tput dim`


is_merge() {
  local commit=$1
  (( $(git log -1 --format=%p $commit | wc -w) > 1 ))
}

is_commit_cherry_picked() {
  local commit=$1
  ! git log -1 --exit-code --grep="cherry picked from commit $commit" &>/dev/null
}

get_PRs() {
  local rev_range=$1
  git log --format="%h" --reverse --merges $rev_range
}

get_commits_in_PR() {
  local source_branch=$1
  local PR=$2
  git log --format=%h --no-merges --reverse $(git merge-base $source_branch $PR^1)..$PR
}

print_commit() {
  local commit=$1
  git log --no-walk --format="%h - %cr - %an - %s" $commit
}

get_commit_rates() {
  # Possible return values:
  # 0 - 100% sure
  # 1 - Unsure - require user decision
  # 2 - 0% sure
  local commit=$1

  # Features
  # 1. Commit message contains given pattern
  local message_rate=$(git log -1 --format=%B $commit | grep -o -f $COMMIT_MESSAGE_PATTERNS_FILE | wc -l)
  local dir_rate=$(git diff-tree --name-only --no-commit-id -r $commit | grep -o -f $DIR_PATTERNS_FILE | wc -l)
  local email_rate=$(git log -1 --format=%ae $commit | grep -o -f $AUTHOR_EMAILS_FILE | wc -l)

  echo "$message_rate $dir_rate $email_rate"
}

skip_PR() {
  local source_branch=$1
  local PR=$2

  local skip=0
  for commit in $(get_commits_in_PR $source_branch $PR); do
    read commit_rate dir_rate email_rate <<< $(get_commit_rates $commit)
    if (( $commit_rate != 0 || $dir_rate != 0 || $email_rate != 0 )); then
      skip=1
      break
    fi
  done

  return $skip
}

cherry_pick() {
  local commit=$1

  merge_opt=""
  if is_merge $commit; then
    merge_opt="-m1"
  fi

  if (( $DRY_RUN == 1 )); then
    return
  fi
  git cherry-pick $merge_opt -x -S -s -Xpatience $commit &>/dev/null || (
    git diff --name-only --diff-filter=U && git mergetool && git commit -s -S
  )
}

read_action_from_file() {
  local commit=$1

  if [ -f "$COMMIT_CACHE_DIR/$commit.action" ]; then
    cat "$COMMIT_CACHE_DIR/$commit.action"
  fi
}

manual_action() {
  local commit=$1
  local key=$(read_action_from_file $commit) && echo -e "\e[0K\r  [$key]"

  if (( $DRY_RUN == 1 )); then
    return
  fi

  echo "${C_BOLD}Matching:$C_NC"
  git log -1 $commit --format=%B | grep --color -f $COMMIT_MESSAGE_PATTERNS_FILE || true
  git log -1 $commit --format=%ae | grep --color -f $AUTHOR_EMAILS_FILE || true
  git diff-tree --no-commit-id -r --name-status $commit | grep --color -f $DIR_PATTERNS_FILE || true

  while [ true ]; do
      [ ! -z "$key" ] || read -p "Possible matching: (b)ackport, (s)kip, (i)nfo, (f)iles, (dD)iff, (q)uit? " -n1 key
  
    case "$key" in
      b)
        echo -e "$C_BOLD${C_GREEN}backport$C_NC"
        cherry_pick $commit
        break
        ;;
      s)
        echo -e "  ${C_DIM}skip$C_NC"
        break
        ;;
      i)
        echo
        git log -1 $commit | grep --color -e$ -f $COMMIT_MESSAGE_PATTERNS_FILE -f $AUTHOR_EMAILS_FILE
        ;;
      f)
        echo
        git log -1 --format="" --stat $commit | grep --color -e$ -f $DIR_PATTERNS_FILE
        ;;
      d)
        echo
        git difftool -x 'echo $BASE; colordiff -p --suppress-common-lines -y -W$(tput cols)'  $commit~ $commit -- $(git diff-tree --no-commit-id -r --name-only $commit | grep -f $DIR_PATTERNS_FILE)
        ;;
      D)
        echo
        git difftool -x "colordiff -y -W$(tput cols)"  $commit~ $commit
        ;;
      q)
        echo
        echo "User aborted: $commit";
        exit 1
        ;;
      *)
        echo "Wrong option: $key"
        ;;
    esac
  done
}

classify_commit() {
  local commit=$1
  local files=$(git diff-tree --no-commit-id -r --name-only $commit)
  declare -A CLASS_COMPONENTS=(
    [frontend]='/frontend/|\.ts$'
    [backend]='/controllers/|/services/'
    [api]='/api/|/controllers/'
    [doc]='^doc/|\.rst$'
    [test]='coveragerc|test|qa/|spec.ts$'
    [branding]='(png|jpg|svg|ico|css|gif)$'
    )
  declare -A CLASS_FEATURES=(
    [pool]='pool'
    [rgw]='rgw'
    [rbd]='rbd'
    [isci]='isci|tcmu'
    [rbd_mirror]='rbd_mirror'
    [host]='host'
    [cephfs]='cephfs'
    [config]='configuration'
    [auth]='login|logout|auth|access_control|user|password|credentials'
    [grafana]='grafana'
    [osd]='osd'
    [monitor]='monitor'
    [logging]='logging'
    [roles]='role'
    [landing]='app/ceph/dashboard|health'
    [navigation]='navigation'
    )
  
  components=()
  for class in "${!CLASS_COMPONENTS[@]}"; do
    echo "$files" | grep -iqcP "${CLASS_COMPONENTS[$class]}" && components+=($class)
  done

  features=()
  for class in "${!CLASS_FEATURES[@]}"; do
    echo "$files" | grep -iqcP "${CLASS_FEATURES[$class]}" && features+=($class)
  done
  
  echo "${components[*]} - ${features[*]}"
}

main()
{
  for commit in $@; do
    classes=$(classify_commit $commit)
    #echo "  $C_DIM$(print_commit $commit) - $C_NC$C_BOLD$classes$C_NC"
    echo "$classes"
  done
}

main $@

