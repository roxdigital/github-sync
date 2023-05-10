#!/usr/bin/env bash

teamwork::get_task_id_from_body() {
  local body=$1
  local task_ids=()

  pat='tasks\/([0-9]{1,})'
  while [[ $body =~ $pat ]]; do
    task_ids+=("${BASH_REMATCH[1]}")
    body=${body#*"${BASH_REMATCH[0]}"}
  done

  local task_ids_str
  task_ids_str=$(printf ",%s" "${task_ids[@]}")
  task_ids_str=${task_ids_str:1} # remove initial comma
  echo "$task_ids_str"
}

teamwork::get_project_id_from_task() {
  local -r task_id=$1

  if [ "$ENV" == "test" ]; then
    echo "$task_id"
    return
  fi

  response=$(
    curl "$TEAMWORK_URI/projects/api/v1/tasks/$task_id.json" -u "$TEAMWORK_API_TOKEN"':' |
      jq -r '.["todo-item"]["project-id"]'
  )
  echo "$response"
}

teamwork::get_matching_board_column_id() {
  local -r column_name=$1

  if [ -z "$column_name" ]; then
    return
  fi

  if [ "$ENV" == "test" ]; then
    echo "$TEAMWORK_PROJECT_ID"
    return
  fi

  response=$(
    curl "$TEAMWORK_URI/projects/$TEAMWORK_PROJECT_ID/boards/columns.json" -u "$TEAMWORK_API_TOKEN"':' |
      jq -r --arg column_name "$column_name" '[.columns[] | select(.name | contains($column_name))] | map(.id)[0]'
  )

  if [ "$response" = "null" ]; then
    return
  fi

  echo "$response"
}

teamwork::move_task_to_column() {
  local -r task_id=$TEAMWORK_TASK_ID
  local -r column_name=$1

  if [ -z "$column_name" ]; then
    log::message "No column name provided"
    return
  fi

  local -r column_id=$(teamwork::get_matching_board_column_id "$column_name")
  if [ -z "$column_id" ]; then
    log::message "Failed to find a matching board column for '$column_name'"
    return
  fi

  if [ "$ENV" == "test" ]; then
    log::message "Test - Simulate request. Task ID: $TEAMWORK_TASK_ID - Project ID: $TEAMWORK_PROJECT_ID - Column ID: $column_id"
    return
  fi

  response=$(curl -X "PUT" "$TEAMWORK_URI/tasks/$TEAMWORK_TASK_ID.json" \
    -u "$TEAMWORK_API_TOKEN"':' \
    -H 'Content-Type: application/json; charset=utf-8' \
    -d "{ \"todo-item\": { \"columnId\": $column_id } }")

  log::message "$response"
}

teamwork::add_comment() {
  local -r body=$1
  local -r notify="${2:-false}"

  if [ "$ENV" == "test" ]; then
    log::message "Test - Simulate request. Task ID: $TEAMWORK_TASK_ID - Comment: ${body//\"/}"
    return
  fi

  response=$(curl -X "POST" "$TEAMWORK_URI/tasks/$TEAMWORK_TASK_ID/comments.json" \
    -u "$TEAMWORK_API_TOKEN"':' \
    -H 'Content-Type: application/json; charset=utf-8' \
    -d "{ \"comment\": { \"body\": \"${body//\"/}\", \"notify\": $notify, \"content-type\": \"text\", \"isprivate\": false } }")

  log::message "$response"
}

teamwork::add_tag() {
  local -r tag_name=$1

  if [ "$ENV" == "test" ]; then
    log::message "Test - Simulate request. Task ID: $TEAMWORK_TASK_ID - Tag Added: ${tag_name//\"/}"
    return
  fi

  if [ "$AUTOMATIC_TAGGING" == true ]; then
    response=$(curl -X "PUT" "$TEAMWORK_URI/tasks/$TEAMWORK_TASK_ID/tags.json" \
      -u "$TEAMWORK_API_TOKEN"':' \
      -H 'Content-Type: application/json; charset=utf-8' \
      -d "{ \"tags\": { \"content\": \"${tag_name//\"/}\" } }")

    log::message "$response"
  fi
}

teamwork::update_estimation() {
  local -r estimation=$1

  response=$(curl -X "PUT" "$TEAMWORK_URI/projects/api/v1/tasks/$TEAMWORK_TASK_ID.json" \
    -u "$TEAMWORK_API_TOKEN"':' \
    -H 'Content-Type: application/json; charset=utf-8' \
    -d "{ \"todo-item\": { \"estimated-minutes\": $estimation } }")

  log::message "$response"
}

teamwork::remove_tag() {
  local -r tag_name=$1

  if [ "$ENV" == "test" ]; then
    log::message "Test - Simulate request. Task ID: $TEAMWORK_TASK_ID - Tag Removed: ${tag_name//\"/}"
    return
  fi

  if [ "$AUTOMATIC_TAGGING" == true ]; then
    response=$(curl -X "PUT" "$TEAMWORK_URI/tasks/$TEAMWORK_TASK_ID/tags.json" \
      -u "$TEAMWORK_API_TOKEN"':' \
      -H 'Content-Type: application/json; charset=utf-8' \
      -d "{ \"tags\": { \"content\": \"${tag_name//\"/}\" },\"removeProvidedTags\":\"true\" }")

    log::message "$response"
  fi
}

teamwork::pull_request_opened() {
  local -r pr_url=$(github::get_pr_url)
  local -r pr_title=$(github::get_pr_title)
  local -r user=$(github::get_sender_user)

  teamwork::add_comment "**$user** opened the [$pr_title]($pr_url) PR for this task."

  teamwork::move_task_to_column "$BOARD_COLUMN_OPENED"
  teamwork::update_estimation 15
}

teamwork::pull_request_closed() {
  local -r user=$(github::get_sender_user)
  local -r pr_url=$(github::get_pr_url)
  local -r pr_title=$(github::get_pr_title)
  local -r pr_merged=$(github::get_pr_merged)
  local -r pr_body=$(github::get_pr_body_without_task)

  if [ "$pr_merged" == "true" ]; then
    teamwork::add_comment "
**$user** merged the [$pr_url]($pr_url) PR for this task:

${pr_body}
  "
    teamwork::move_task_to_column "$BOARD_COLUMN_MERGED"
    teamwork::update_estimation 0
  else
    teamwork::add_comment "**$user** closed the [$pr_title]($pr_url) PR for this task."
    teamwork::move_task_to_column "$BOARD_COLUMN_FEEDBACK"
  fi
}

teamwork::pull_request_review_submitted() {
  local -r user=$(github::get_sender_user)
  local -r pr_url=$(github::get_pr_url)
  local -r pr_title=$(github::get_pr_title)
  local -r review_state=$(github::get_review_state)

  if [ "$review_state" == "changes_requested" ]; then
    teamwork::move_task_to_column "$BOARD_COLUMN_FEEDBACK"
    teamwork::add_comment "**$user** requested changes to the [$pr_title]($pr_url) PR for this task."
  fi
}

teamwork::pull_request_review_dismissed() {
  local -r user=$(github::get_sender_user)
  teamwork::move_task_to_column "$BOARD_COLUMN_OPENED"
  teamwork::add_comment "Review on the [$pr_title]($pr_url) PR for this task dismissed by **$user**."
}
