#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

files=("${RESULTS_DIR}"/*.json)
failed=0
has_failures=0
summary_file="${RUNNER_TEMP}/lava-result-summary.md"
known_failures_display_name="$(basename "$KNOWN_FAILURES_FILE")"
known_failures_file="${RUNNER_TEMP}/known-failures.json"
known_failure_details_file="${RUNNER_TEMP}/known-failure-details.md"
unexpected_details_file="${RUNNER_TEMP}/unexpected-failure-details.md"
: > "$known_failure_details_file"
: > "$unexpected_details_file"

append_known_failure() {
  printf -- '- %s\n' "$1" >> "$known_failure_details_file"
  has_failures=1
}

append_unexpected_failure() {
  printf -- '- %s\n' "$1" >> "$unexpected_details_file"
  has_failures=1
  failed=1
}

normalize_known_failures() {
  ruby -ryaml -rjson -e '
    def fetch_value(hash, key)
      return nil unless hash.is_a?(Hash)
      hash[key] || hash[key.to_sym]
    end

    def failures_from(config)
      case config
      when Array
        config
      when Hash
        fetch_value(config, "failures") ||
          fetch_value(config, "known_failures") ||
          fetch_value(config, "test_failures") || []
      else
        []
      end
    end

    config = YAML.load_file(ARGV[0]) || {}
    branch = ARGV[1].to_s
    failures = []

    if config.is_a?(Array)
      failures = config
    elsif config.is_a?(Hash)
      failures += failures_from(config)
      branches = fetch_value(config, "branches")
      if branches.is_a?(Hash)
        failures += failures_from(fetch_value(branches, "*"))
        failures += failures_from(fetch_value(branches, branch)) unless branch.empty?
      end
    end

    normalized = failures.map do |entry|
      if entry.is_a?(Hash)
        target = fetch_value(entry, "target") || "*"
        name = fetch_value(entry, "name") || fetch_value(entry, "test")
        result = fetch_value(entry, "result") || "*"
      else
        value = entry.to_s
        parts = value.split("::", 2)
        target = parts.length == 2 ? parts[0] : "*"
        name = parts.length == 2 ? parts[1] : value
        result = "*"
      end
      {"target" => target.to_s, "name" => name.to_s, "result" => result.to_s}
    end.reject { |failure| failure["name"].empty? }

    puts JSON.generate(normalized)
  ' "$KNOWN_FAILURES_FILE" "${KNOWN_FAILURE_BRANCH:-}"
}

if [ -f "$KNOWN_FAILURES_FILE" ]; then
  if ! normalize_known_failures > "$known_failures_file"; then
    echo "[]" > "$known_failures_file"
    append_unexpected_failure "Unable to parse \`${known_failures_display_name}\`; known failure list is unavailable."
  fi
else
  echo "[]" > "$known_failures_file"
  append_unexpected_failure "Unable to load \`${known_failures_display_name}\`; known failure list is unavailable."
fi

known_failure_count="$(jq 'length' "$known_failures_file")"

{
  echo "### Test result"
  echo ""
  echo "Known failures configured: ${known_failure_count}"
  echo ""
} >> "$GITHUB_STEP_SUMMARY"

{
  echo "### Test results"
  echo ""
  echo "Workflow run: [${GITHUB_RUN_ID}](https://github.com/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID})"
  echo ""
  echo "Known failures configured: ${known_failure_count}"
  echo ""
} > "$summary_file"

if [ "${#files[@]}" -eq 0 ]; then
  echo "No LAVA result JSON artifacts were found." >> "$GITHUB_STEP_SUMMARY"
  printf '::error title=test-results::No LAVA result JSON artifacts were found\n'
  append_unexpected_failure "No LAVA result JSON artifacts were found."
else
  {
    echo "| Target | Pass | Non-pass | Total |"
    echo "| --- | :---: | :---: | :---: |"
  } >> "$GITHUB_STEP_SUMMARY"

  {
    echo "| Target | Pass | Non-pass | Total |"
    echo "| --- | :---: | :---: | :---: |"
  } >> "$summary_file"

  for file in "${files[@]}"; do
    target="$(basename "$file" .json)"
    target="${target#Tests-}"
    total="$(jq 'length' "$file")"
    pass="$(jq '[.[] | select(.result == "pass")] | length' "$file")"
    non_pass="$(jq '[.[] | select(.result != "pass")] | length' "$file")"

    printf '| %s | %s | %s | %s |\n' "$target" "$pass" "$non_pass" "$total" >> "$GITHUB_STEP_SUMMARY"
    printf '| %s | %s | %s | %s |\n' "$target" "$pass" "$non_pass" "$total" >> "$summary_file"

    if [ "$total" -eq 0 ]; then
      append_unexpected_failure "\`${target}\` result artifact is empty."
    fi

    if [ "$non_pass" -ne 0 ]; then
      while IFS=$'\t' read -r test_name result; do
        [ -n "$test_name" ] || continue
        if jq -e \
          --arg target "$target" \
          --arg name "$test_name" \
          --arg result "$result" \
          'any(.[]; (.target == "*" or .target == $target) and .name == $name and (.result == "*" or .result == $result))' \
          "$known_failures_file" >/dev/null; then
          append_known_failure "\`${target}\`: \`${test_name}\` => \`${result}\`."
          printf '::notice title=test-results::known failure: %s: %s => %s\n' "$target" "$test_name" "$result"
        else
          append_unexpected_failure "\`${target}\`: \`${test_name}\` => \`${result}\`."
          printf '::error title=test-results::unexpected failure: %s: %s => %s\n' "$target" "$test_name" "$result"
        fi
      done < <(jq -r '.[] | select(.result != "pass") | [.name, .result] | @tsv' "$file")
    fi
  done
fi

if [ -s "$known_failure_details_file" ] || [ -s "$unexpected_details_file" ]; then
  {
    echo ""
    echo "<details>"
    echo "<summary>Failure summary</summary>"
    echo ""
  } >> "$summary_file"

  if [ -s "$known_failure_details_file" ]; then
    {
      echo "#### Known failures"
      cat "$known_failure_details_file"
      echo ""
    } >> "$summary_file"
  fi

  if [ -s "$unexpected_details_file" ]; then
    {
      echo "#### Unexpected failures"
      cat "$unexpected_details_file"
      echo ""
    } >> "$summary_file"
  fi

  echo "</details>" >> "$summary_file"
fi

if [ "$failed" -ne 0 ]; then
  {
    echo ""
    echo "Result: blocked because unexpected failures were found."
  } >> "$summary_file"
  echo "test-results result: failed"
elif [ "$has_failures" -ne 0 ]; then
  {
    echo ""
    echo "Result: continuing because all observed test failures are listed in ${known_failures_display_name}."
  } >> "$summary_file"
  echo "test-results result: passed with known failures"
else
  echo "test-results result: passed"
fi

{
  echo "failed=$failed"
  echo "has_failures=$has_failures"
  echo "summary_file=$summary_file"
  echo "known_failure_count=$known_failure_count"
} >> "$GITHUB_OUTPUT"
