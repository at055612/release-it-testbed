#!/usr/bin/env bash

##########################################################################
# Version: <BUILD_VERSION>
# Date: <BUILD_DATE>
#
# Script to record changelog entries in individual files to get around
# the issue of merge conflicts on the CHANGELOG file when doing PRs.
#
# Credit for this idea goes to 
# https://about.gitlab.com/blog/2018/07/03/solving-gitlabs-changelog-conflict-crisis/
# 
# Change log entries are stored in files in <repo_root>/unreleased_changes
# This script is used in conjunction with tag_release.sh which adds the
# change entries to the CHANGELOG at release time.
##########################################################################


set -euo pipefail

IS_DEBUG=${IS_DEBUG:-false}
UNRELEASED_DIR_NAME="unreleased_changes"

setup_echo_colours() {
  # Exit the script on any error
  set -e

  # shellcheck disable=SC2034
  if [ "${MONOCHROME:-false}" = true ]; then
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    BLUE2=''
    DGREY=''
    NC='' # No Colour
  else 
    RED='\033[1;31m'
    GREEN='\033[1;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[1;34m'
    BLUE2='\033[1;34m'
    DGREY='\e[90m'
    NC='\033[0m' # No Colour
  fi
}

info() {
  echo -e "${GREEN}$*${NC}"
}

warn() {
  echo -e "${YELLOW}WARNING${NC}: $*${NC}" >&2
}

error() {
  echo -e "${RED}ERROR${NC}: $*${NC}" >&2
}

error_exit() {
  error "$@"
  exit 1
}

debug_value() {
  local name="$1"; shift
  local value="$1"; shift
  
  if [ "${IS_DEBUG}" = true ]; then
    echo -e "${DGREY}DEBUG ${name}: ${value}${NC}"
  fi
}

debug() {
  local str="$1"; shift
  
  if [ "${IS_DEBUG}" = true ]; then
    echo -e "${DGREY}DEBUG ${str}${NC}"
  fi
}

get_git_issue_from_branch() {

  local current_branch
  current_branch="$(git rev-parse --abbrev-ref HEAD)"

  local git_issue_from_branch
  git_issue_from_branch="$( \
    echo "${current_branch}" \
    | grep \
      --only-matching \
      --perl-regexp '(?<=^gh-)[1-9][0-9]*' \
      )"

  if [[ -z "${git_issue_from_branch}" ]]; then
    error_exit "Unable to establish GitHub issue number from" \
      "branch ${BLUE}${current_branch}${NC}"
  fi
  echo "${git_issue_from_branch}"
}

establish_git_remote_namespace_and_repo() {
  # 'origin https://github.com/gchq/stroom.git (fetch)' => 'gchq stroom'
  # read the space delimited values into an array so we can split them
  local namespace_and_repo=()
  IFS=" " read -r -a namespace_and_repo <<< "$( \
    git remote -v \
      | grep "(fetch)" \
      | sed -r 's#.*[/:]([^/]+)/(.*)\.git \(fetch\)#\1 \2#')"

  debug_value "namespace_and_repo" "${namespace_and_repo[*]}"

  # global scope
  git_namespace=""
  git_repo=""

  if [[ "${#namespace_and_repo[@]}" -ne 2 ]]; then
    warn "Unable to parse git namespace and repo from the remote URL."
  else
    git_namespace="${namespace_and_repo[0]}"
    git_repo="${namespace_and_repo[1]}"

    debug_value "git_namespace" "${git_namespace}"
    debug_value "git_repo" "${git_repo}"
  fi
}

validate_git_issue() {
  local git_issue="$1"; shift
  debug "Validating [${git_issue}]"
  
  if [[ ! "${git_issue}" =~ ^([_.a-zA-Z0-9-]+\/[_.a-zA-Z0-9-]+\#[0-9]+|[0-9]+)$ ]]; then
    error_exit "Invalid github issue number ${BLUE}${git_issue}${NC}." \
      "Should be of the form ${BLUE}1234${NC}," \
      "${BLUE}namespace/repo#1234${NC}, ${BLUE}0${NC} or ${BLUE}auto${NC}."
  fi

  # global scope
  issue_title=""

  if [[ ! "${git_issue}" = "0" ]]; then
    local issue_namespace
    local issue_repo
    local issue_number
    if [[ "${git_issue}" =~ ^[1-9][0-9]*$ ]]; then
      # Issue in this repo so use the values we got from the local repo
      issue_namespace="${git_namespace}"
      issue_repo="${git_repo}"
      issue_number="${git_issue}"
    else
      # Fully qualified issue so extract the parts by replacing / and # with
      # space then reading into an array which will split on space
      local parts=()
      IFS=" " read -r -a parts <<< "${git_issue//[\#\/]/ }"
      issue_namespace="${parts[0]}"
      issue_repo="${parts[1]}"
      issue_number="${parts[2]}"
    fi

    debug_value "issue_namespace" "${issue_namespace}"
    debug_value "issue_repo" "${issue_repo}"
    debug_value "issue_number" "${issue_number}"

    local github_issue_url="https://api.github.com/repos/${issue_namespace}/${issue_repo}/issues/${issue_number}"

    debug_value "github_issue_url" "${github_issue_url}"

    local curl_return_code=0
    # Turn off exit on error so we can get the curl return code in the subshell
    set +e 

    if command -v jq >/dev/null 2>&1; then
      # jq is available so use it
      issue_title="$( \
        curl \
          --silent \
          --fail \
          "${github_issue_url}" \
        | jq \
          --raw-output \
          '.title' \
      )"
      curl_return_code=$?
    else
      # no jq so fall back to grep
      issue_title="$( \
        curl \
          --silent \
          --fail \
          "${github_issue_url}" \
        | grep \
          --only-matching \
          --prl-regexp \
          '(?<="title": ").*(?=",)' \
      )"
      curl_return_code=$?
    fi
    set -e

    debug_value "curl_return_code" "${curl_return_code}"

    # curl_return_code is NOT the http status, just sucess/fail
    if [[ "${curl_return_code}" -ne 0 ]]; then
      # curl failed so check to see what the status code was
      local http_status_code
      http_status_code="$( \
        curl \
          --silent \
          --output /dev/null \
          --write-out "%{http_code}" \
          "${github_issue_url}"\
      )"
      debug_value "http_status_code" "${http_status_code}"

      if [[ "${http_status_code}" = "404" ]]; then
        error_exit "Issue ${BLUE}${git_issue}${NC} does not exist on GitHub"
      else
        warn "Unable to obtain issue title for issue ${BLUE}${issue_number}${NC}" \
          "from GitHub (HTTP status: ${BLUE}${http_status_code}${NC})"
        issue_title=""
      fi
    else
      info "Issue title: ${BLUE}${issue_title}${NC}"
    fi
  fi
}

validate_in_git_repo() {
  if ! git rev-parse --show-toplevel > /dev/null 2>&1; then
    error_exit "You are not in a git repository. This script should be run from" \
      "inside a repository.${NC}"
  fi
}

is_existing_change_file_present() {
  local git_issue="$1"; shift
  local change_text="$1"; shift

  local git_issue_str
  git_issue_str="$(format_git_issue_for_filename "${git_issue}")"

  local existing_files=()

  for existing_file in "${unreleased_dir}"/*__"${git_issue_str}".md; do
    if [[ -f "${existing_file}" ]]; then
      debug_value "existing_file" "${existing_file}"
      local filename
      filename="$(basename "${existing_file}" )"
      existing_files+=( "${filename}" )
    fi
  done

  debug_value "existing_files" "${existing_files[@]:-()}"

  local existing_file_count="${#existing_files[@]}"
  debug_value "existing_file_count" "${existing_file_count}"

  if [[ "${existing_file_count}" -eq 0 ]]; then
    debug "File does not exist"
    return 1
  else 
    # Multiple files exist for this 
    debug "${existing_file_count} files exist"

    info "Change file(s) already exist for this issue:"
    echo

    list_unreleased_changes "${git_issue_str}"

    echo
    echo "Do you want to create a new change file for the issue or open an existing one?"
    echo "If it is a different change tied to the same issue then you should create a new"
    echo "file to avoid merge conflicts."

    # Build the menu options
    local menu_item_arr=()
    menu_item_arr+=( "Create new file" )
    for filename in "${existing_files[@]}"; do
      menu_item_arr+=( "Open ${filename}" )
    done

    COLUMNS=1
    select user_input in "${menu_item_arr[@]}"; do
      if [[ "${user_input}" = "Create new file" ]]; then
        write_change_entry "${git_issue}" "${change_text:-}"
        break
      elif [[ "${user_input}" =~ ^Open ]]; then
        local chosen_file_name="${user_input#Open }"
        debug_value "chosen_file_name" "${chosen_file_name}"
        open_file_in_editor "${unreleased_dir}/${chosen_file_name}"
        validate_issue_line "${unreleased_dir}/${chosen_file_name}"
        break
      else
        echo "Invalid option. Try another one."
        continue
      fi
    done

    return 0
  fi
}

format_git_issue_for_filename() {
  local git_issue="$1"; shift

  local git_issue_str
  if [[ "${git_issue}" = "0" ]]; then
    git_issue_str="0"
  else
    # replace / and # with _
    git_issue_str="${git_issue//[\#\/]/_}"
    #debug_value "git_issue_str" "${git_issue_str}"
  fi
  echo "${git_issue_str}"
}

write_change_entry() {
  local git_issue="$1"; shift
  local change_text="$1"; shift

  local date_str
  date_str="$(date --utc +%Y%m%d_%H%M%S_%3N)"

  local git_issue_str
  git_issue_str="$(format_git_issue_for_filename "${git_issue}")"
  
  # Use two underscores to help distinguish the date from the issue part
  # which may itself contain underscores.
  local filename="${date_str}__${git_issue_str}.md"
  local change_file="${unreleased_dir}/${filename}"

  debug_value "change_file" "${change_file}"

  if [[ -e "${change_file}" ]]; then
    error_exit "File ${BLUE}${change_file}${NC} already exists"
  fi

  local issue_prefix="Issue **"
  local issue_suffix="** : "

  local line_prefix="* "

  local issue_part
  if [[ "${git_issue}" = "0" ]]; then
    issue_part=""
  elif [[ "${git_issue}" =~ ^[0-9]+$ ]]; then
    # * Issue **#1234** : My change text
    issue_part="${issue_prefix}#${git_issue}${issue_suffix}"
  else
    # * Issue **gchq/stroom#1234** : 
    issue_part="${issue_prefix}${git_issue}${issue_suffix}"
  fi

  local change_entry_line="${line_prefix}${issue_part}${change_text}"
  local all_content

  # Craft the content of the file
  # shellcheck disable=SC2016
  all_content="$( \
    echo "${change_entry_line}" 
    echo
    echo
    echo '```sh'
    if [[ -n "${issue_title}" ]]; then
      echo "# ********************************************************************************"
      echo "# Issue title: ${issue_title}"
      echo "# ********************************************************************************"
      echo
    fi
    echo "# ONLY the top line will be included in the CHANGELOG."
    echo "# Entries should be in GitHub flavour markdown and should be written on a SINGLE"
    echo "# line with no hard breaks. You can have multiple change files for a single GitHub issue."
    echo "#"
    echo "# Examples of acceptable entires are:"
    echo "#"
    echo "#"
    echo "# * Issue **1234** : A change with an associated GitHub issue in this repository"
    echo "#"
    echo "# * Issue **namespace/other-repo#1234** : A change with an associated GitHub issue in another repository"
    echo "#"
    echo "# * A change with no associated GitHub issue."
    echo '```'
  )"

  info "Writing file ${BLUE}${change_file}${GREEN}:"
  info "${DGREY}------------------------------------------------------------------------${NC}"
  info "${YELLOW}${change_entry_line}${NC}"
  info "${DGREY}------------------------------------------------------------------------${NC}"

  echo -e "${all_content}" > "${change_file}"

  if [[ -z "${change_text}" ]]; then
    open_file_in_editor "${change_file}"

    validate_issue_line "${change_file}"
  fi
}

# Return zero if the file was changed, else non-zero
open_file_in_editor() {
  local file_to_open="$1"; shift
  
  local return_code=0
  local md5_before
  md5_before="$(md5sum "${file_to_open}" | cut -d' ' -f1)"

  local editor
  editor="${VISUAL:-${EDITOR:-vi}}"

  info "Opening file ${BLUE}${file_to_open}${GREEN} in editor" \
    "(${BLUE}${editor}${GREEN})${NC}"

  read -n 1 -s -r -p "Press any key to continue"
  echo

  # Open the user's preferred editor or vi/vim if not set
  "${editor}" "${file_to_open}"

  local md5_after
  md5_after="$(md5sum "${file_to_open}" | cut -d' ' -f1)"

  if [[ "${md5_before}" = "${md5_after}" ]]; then
    debug "File unchanged"
    return 1
  else
    debug "File changed"
    return 0
  fi

  debug_value "return_code" "${return_code}" 
}

validate_issue_line() {
  local change_file="$1"; shift
  # Used to look for lines that might be a change entry
  local simple_issue_line_regex="^\* [A-Z]"

  # A more complex regex to make sure the change entries are a consistent format
  # https://regex101.com/r/fOO8lQ/1
  local issue_line_regex="^\* (Issue \*\*([a-zA-Z0-9_\-.]+\/[a-zA-Z0-9_\-.]+\#[0-9]+|#[0-9]+)\*\* : )?[A-Z][\w .!?\`\"'*\-]+$"

  debug "Validating file ${change_file}"

  local issue_line_count
  issue_line_count="$( \
    grep \
      --count \
      --perl-regexp \
      "${simple_issue_line_regex}" \
      "${change_file}"
    )"

  debug_value "issue_line_count" "${issue_line_count}"

  if [[ "${issue_line_count}" -eq 0 ]]; then
      error_exit "No change entry line found in ${BLUE}${change_file}${NC}"
  elif [[ "${issue_line_count}" -gt 1 ]]; then
      error "Multiple change entry lines found in ${BLUE}${change_file}${NC}:"
      echo -e "${DGREY}------------------------------------------------------------------------${NC}"
      echo -e "$(grep --perl-regexp "${simple_issue_line_regex}" "${change_file}" )"
      echo -e "${DGREY}------------------------------------------------------------------------${NC}"
      echo -e "Validation regex: ${BLUE}${simple_issue_line_regex}${NC}"
      exit 1
  else
    if ! head -n1 "${change_file}" | grep --quiet --perl-regexp "${issue_line_regex}"; then
      error "The change entry is not valid in ${BLUE}${change_file}${NC}:"
      echo -e "${DGREY}------------------------------------------------------------------------${NC}"
      echo -e "$(head -n1 "${change_file}" )"
      echo -e "${DGREY}------------------------------------------------------------------------${NC}"
      echo -e "Validation regex: ${BLUE}${issue_line_regex}${NC}"
      exit 1
    fi
  fi
}

list_unreleased_changes() {

  # if no git issue is provided use a wildcard so we can get all issues
  local git_issue_str="${1:-*}"; shift
  debug_value "git_issue_str" "${git_issue_str}"
  local found_change_files=false
  local list_output=""

  for file in "${unreleased_dir}/"*__${git_issue_str}.md; do
    if [[ -f "${file}" ]]; then
      local filename
      local change_entry_line

      found_change_files=true
      filename="$(basename "${file}" )"

      change_entry_line="$( \
        head \
          -n1 \
          "${file}" \
      )"
      list_output+="${BLUE}${filename}${NC}:\n${YELLOW}${change_entry_line}${NC}\n\n"
    fi
  done

  #if [[ "${#entry_map[@]}" -gt 0 ]]; then
  if [[ "${found_change_files}" = true ]]; then
    #for filename in "${!MYMAP[@]}"; do echo $K; done

    # Remove the trailing blank lines
    list_output="$(echo -e "${list_output}" | head -n-2 )"

    echo -e "${list_output}"
  else
    info "There are no unreleased changes"
  fi
}

main() {
  #local SCRIPT_DIR
  #SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
  #debug_value "SCRIPT_DIR" "${SCRIPT_DIR}"

  setup_echo_colours

  if [[ $# -eq 0 ]]; then
    error "Invalid arguments"
    echo -e "Usage: $0 github_issue [change_text]" >&2
    echo -e "git_issue - GitHub issue number in one of the following formats:" >&2
    echo -e "            0 - No issue exists for this change" >&2
    echo -e "            n - Just the issue number." >&2
    echo -e "            namespace/repo#n - Issue number on another repo." >&2
    echo -e "            auto - Will derive the issue number from the current branch." >&2
    echo -e "            list - List all unreleased issues." >&2
    echo -e "change_text - The change text in github markdown format. This will be appended to" >&2
    echo -e "              change log entry" >&2
    echo -e "E.g:   $0 1234 \"Fix nasty bug\"" >&2
    echo -e "E.g:   $0 gchq/stroom#1234 \"Fix nasty bug\"" >&2
    echo -e "E.g:   $0 1234" >&2
    echo -e "E.g:   $0 auto \"Fix nasty bug\"" >&2
    echo -e "E.g:   $0 0 \"Fix something without an issue number\"" >&2
    echo -e "E.g:   $0 list" >&2
    exit 1
  fi

  local git_issue="$1"; shift
  local change_text="${1:-}"

  debug_value "git_issue" "${git_issue}"
  debug_value "change_text" "${change_text}"

  # TODO validate change_text against the text part of issue_line_regex if
  # it is set

  validate_in_git_repo

  establish_git_remote_namespace_and_repo

  local repo_root_dir
  repo_root_dir="$(git rev-parse --show-toplevel)"
  local unreleased_dir="${repo_root_dir}/${UNRELEASED_DIR_NAME}"
  mkdir -p "${unreleased_dir}"

  if [[ "${git_issue}" = "list" ]]; then
    list_unreleased_changes ""
  else
    if [[ "${git_issue}" = "auto" ]]; then
      git_issue="$(get_git_issue_from_branch)"
    else
      validate_git_issue "${git_issue}"
    fi

    if [[ "${git_issue}" = "0" ]] \
      || ! is_existing_change_file_present "${git_issue}" "${change_text:-}"; then

      write_change_entry "${git_issue}" "${change_text:-}"
    fi
  fi
}

main "$@"

# vim: set tabstop=2 shiftwidth=2 expandtab:
