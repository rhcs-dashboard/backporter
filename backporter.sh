#!/bin/bash
set -euo pipefail

readonly true=0
readonly false=1

error() {
  echo "$1" 1>&2
  exit ${2:-"1"}
}

warning() {
  echo "$1" 1>&2
}

(( $BASH_VERSINFO >= 4 )) || error "ERROR: Bash 4 or above required"

export GIT_PAGER=""

DRY_RUN=$false
CHERRY_PICK_STRATEGY=COMMITS # CPS: PR, MIXED, COMMITS
CPS_MIXED_COMMIT_THRESHOLD=0

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


declare -A CACHED_CMD_OUTPUT
declare -A CACHED_CMD_RC
declare -A CACHED_CMD_COUNT

is_merge() {
  local commit=$1
  (( $(git log -1 --format=%p $commit | wc -w) > 1 ))
}

is_cherry_picked() {
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

FORMAT_COMMIT='%h - %cr - %an - %s'

format_commit() {
  local commit=$1
  if is_merge $commit; then
    subject=$(git log -1 --format="%b" $commit | dos2unix | sed -n '1,/^$/{/^$/!p}' | tr '\n' ',' | tr -s '[:space:]' ' ')
    [ -z "$subject" ] && subject=$(git log -1 --format="%s" $commit)
    echo "$(git log -1 --format="%h - %cr - %an" $commit) - $subject"
  else
    git log -1 --format="$FORMAT_COMMIT" $commit
  fi
}

print_commit() {
  local commit=$1; shift
  local type=$1; shift
  local other=$@

  local PRE=""
  if is_merge $commit; then
    PRE+=""
  else
    PRE+="  "
  fi

  case "$type" in
    SKIP)     PRE+="$C_DIM[S]" ;;
    BACKPORT) PRE+="$C_GREEN[X]" ;;
    ASK)      PRE+="$C_DIM$C_GREEN[?]" ;;
    DONE)     PRE+="$C_YELLOW[B]" ;;
    PICK)     PRE+="$C_DIM$C_GREEN[P]" ;;
    *)  error "Unknown print_commit type: $type" ;;
  esac
  PRE+=" - "

  POST=""
  if [ ! -z "$other" ]; then
    POST+=" - $other"
  fi

  echo -e "$PRE$(format_commit $commit)$POST$C_NC"
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

commit_score() {
  echo $[ ($1>0)*35 + ($2>0)*30 + ($3>0)*35 ]
}


backport_commit() {
  local commit=$1

  if (( $DRY_RUN == $true )); then
    return $true
  fi
  
  if is_merge $commit; then
    git cherry-pick -m1 -n -x -S -s -Xpatience $commit &>/dev/null || {
          git diff --name-only --diff-filter=U &&
          git mergetool 
        }
    git commit -s -S -m "$(tail -n +3 $(git rev-parse --show-toplevel)/.git/MERGE_MSG)" || error "Aborted"
  else
    git cherry-pick -x -S -s -Xpatience $commit &>/dev/null || {
      git diff --name-only --diff-filter=U &&
      git mergetool &&
      git commit -s -S || error "Aborted"
    }
  fi
}

read_action_from_file() {
  local commit=$1

  if [ -f "$COMMIT_CACHE_DIR/$commit.action" ]; then
    cat "$COMMIT_CACHE_DIR/$commit.action"
  fi
}

save_action_to_file() {
  local commit=$1; shift
  local action=$1

  echo $action > "$COMMIT_CACHE_DIR/$commit.action"
}

manual_action() {
  local commit=$1; shift
  local source_branch=$@
  local key=$(read_action_from_file $commit)

  local rc=$true

  if (( $DRY_RUN == $true )); then
    [ -z "$key" ] || echo -en " -  Action_from_file: [$key]"
    return $true
  fi

  echo "${C_BOLD}Matching:$C_NC"
  git log -1 $commit --format=%B | grep --color -f $COMMIT_MESSAGE_PATTERNS_FILE || true
  git log -1 $commit --format=%ae | grep --color -f $AUTHOR_EMAILS_FILE || true
  git diff-tree --no-commit-id -r --name-status $commit | grep --color -f $DIR_PATTERNS_FILE || true

  while [ true ]; do
    [ ! -z "$key" ] || read -p "Possible matching: (bB)ackport, (sS)kip,$(is_merge $commit && echo " (pP)ick, (c)ommits,") (i)nfo, (f)iles, (dD)iff, (q)uit? " -n1 key
  
    case "$key" in
      [bB])
        echo -e "  $C_BOLD${C_GREEN}backport$C_NC"
        backport_commit $commit
        [ $key == "B" ] && save_action_to_file $commit b
        break
        ;;
      [sS])
        echo -e "  ${C_BOLD}skip$C_NC"
        [ $key == "S" ] && save_action_to_file $commit s
        rc=$false
        break
        ;;
      c)
        echo
        is_merge $commit || error "commit $commit is not merge commit"
        git log --format="$FORMAT_COMMIT" --no-merges --reverse $(git merge-base $source_branch $commit^1)..$commit
        ;;

      [pP])
        is_merge $commit || error "commit $commit is not merge commit"
        echo -e "  pick"
        [ $key == "P" ] && save_action_to_file $commit p
        rc=$false
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
        error "User aborted: $commit";
        ;;
      *)
        echo "Wrong option: $key"
        ;;
    esac
    key=""
  done

  return $rc
}

classify_PR() {
  # return value:
  # 0 - unrelated -> skip
  # 1 - partial -> proceed per commit
  # 2 - patial but likely -> ask
  # 3 - total -> merge full PR
  # 4 - all_cherrypicked - > skip

  local source_branch=$1
  local PR=$2

  local all_cherrypicked=$true
  local num_of_commits=0
  local sum_of_score=0
  local commit
  for commit in $(get_commits_in_PR $source_branch $PR); do
    (( num_of_commits++ ))

    local decision=$(read_action_from_file $commit)
    local rates=$(get_commit_rates $commit)
    local score=$(commit_score $rates)

    if [ "$decision" == 's' ]; then
      score=0
    elif [ "$decision" == 'b' ]; then
      score=100
    fi
    (( sum_of_score+=$score ))
     
    if ! is_cherry_picked $commit; then
      all_cherrypicked=$false
    fi
  done

  echo "$num_of_commits $sum_of_score"

  local class
  if (( $all_cherrypicked == $true)); then
    class=4
  elif (( $sum_of_score >= 100*$num_of_commits )); then
    # PR cherry-picks
    class=3
  elif (( $sum_of_score >= 50*$num_of_commits )); then
    # Ask whether PR or per-commit cherry-picks
    class=2
  elif (( $sum_of_score > 0 )); then
    # Commit cherry-picks
    class=1
  else
    class=0
  fi    

  # When PR/merge cherry-picking is disable, classes 2-3 -> 1
  if [ $CHERRY_PICK_STRATEGY == COMMITS  ] && (( $class == 2 || $class == 3)); then
      class=1
  elif [ $CHERRY_PICK_STRATEGY == MIXED ] && (( $num_of_commits < $CPS_MIXED_COMMIT_THRESHOLD )); then
    class=1
  fi

  return $class
}

process_merge() {
  local commit=$1; shift
  local main_branch=$1; shift

  decision=$(read_action_from_file $commit)
  
  if [ "$decision" == 's' ]; then
    print_commit $commit SKIP '<from_file>'
  elif [ "$CHERRY_PICK_STRATEGY" == COMMITS ]; then
    print_commit $commit PICK
    return $true
  else
    d=($(classify_PR $main_branch $commit)); class=$?
    num_of_commits=${d[0]}
    sum_of_score=${d[1]}
    post="[commits: $num_of_commits] - [score: $sum_of_score]"

    if (( $class == 0 )) && [ "$decision" != 'b' ]; then
      print_commit $commit SKIP $post
    elif [ "$decision" == 'b' ] || (( $class == 3 )); then
      print_commit $commit BACKPORT $post
      backport_commit $commit
    elif (( $class == 2 )); then
      print_commit $commit ASK $post
      manual_action $commit $main_branch || return $true
    elif (( $class == 4 )) || is_cherry_picked $commit ; then
      print_commit $commit DONE $post
    else
      # class=1
      print_commit $commit PICK $post
      return $true
    fi
  fi

  return $false
}

process_commit() {
  local commit=$1
  local rc=$false

  decision=$(read_action_from_file $commit)
  rates=$(get_commit_rates $commit)
  score=$(commit_score $rates)

  if [ "$decision" == 's' ]; then
    print_commit $commit SKIP $rates "- <from_file>"
  elif (( $score == 0 )); then
    print_commit $commit SKIP $rates
  elif is_cherry_picked $commit; then
    print_commit $commit DONE
    rc=$true
  elif [ "$decision" == 'b' ]; then
    print_commit $commit BACKPORT $rates "- <from_file>"
    backport_commit $commit
    rc=$true
  elif (( $score == 100 )); then
    print_commit $commit BACKPORT $rates
    backport_commit $commit
    rc=$true
  else
    print_commit $commit ASK $rates
    manual_action $commit
    rc=$?
  fi

  return $rc
}

main()
{
  local start_commit=$1; shift
  local end_commit=$1; shift

  local PR
  for PR in $(get_PRs $start_commit...$end_commit); do
    if process_merge $PR $end_commit; then
      local commit
      local any_merged=$false
      for commit in $(get_commits_in_PR $end_commit $PR); do
        process_commit $commit && any_merged=$true
      done

      if (( $any_merged == $false )); then
        echo "No commits merged for PR $PR. Decision to skip saved!"
        save_action_to_file $PR s
      fi

    fi
  done
}

main $1 $2
