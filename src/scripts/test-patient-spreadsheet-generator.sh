#!/usr/bin/env bash
set -euo pipefail

log () { echo "$(date) [${1}] ${2}"; }

new-ccg-token() {
  local clientId="${1}" clientSecret="${2}" audience="${3}" oauthUrl="${4}" scope="${5}" launch="${6}"
  bash <(curl -sH"Authorization: Bearer $GITHUB_TOKEN" "https://raw.githubusercontent.com/department-of-veterans-affairs/shanktopus/master/bin/system-authorization-token") \
    --client-id "${clientId}" \
    --client-secret "${clientSecret}" \
    --audience "${audience}" \
    --oauth-url "${oauthUrl}" \
    --scope "${scope}" \
    --launch "${launch}" \
    --print-token \
    lab \
    | jq -r '.access_token'
}

sendSlackErrorMessage() {
  slack-send \
  --channel ${SLACK_CHANNEL} \
  --type failure \
  --icon-emoji rotating_light \
  --title "${ENVIRONMENT} Generate Test Patient Spreadsheet Job" \
  --webhook-url ${SLACK_WEBHOOK} \
  --body "Failed to generate test patient spreadsheet ${1}"
}

generateTestPatientSpreadsheet() {
  local api="${1}" templateFile="${2}" outputFile="${3}" testPatients="${4}" clientId="${5}" clientSecret="${6}" audience="${7}" oauthUrl="${8}" scope="${9}" launch="${10}"
  local workFile baseUrl patientFields resourceStaticFields resourceJqFields patientFieldValues staticFieldValues
  workFile=$(mktemp -p "${WORK:-/tmp}")
  baseUrl=$(jq -r '.baseUrl' "${templateFile}")

  if [ ! -f "${templateFile}" ]; then
    log "ERROR" "${templateFile} does not exist."
    return 1
  fi

  patientFields=$(jq -r '.patientFields[].name' "${templateFile}" | tr '\n' ' ')
  resourceStaticFields=()
  resourceJqFields=()

  for i in $(seq 0 $(($(jq '.resources | length' "${templateFile}")-1))); do
    for staticField in $(jq -r ".resources[${i}].staticFields[].name" "${templateFile}"); do
      if [[ ! " ${resourceStaticFields[*]} " =~ [[:space:]]${staticField}[[:space:]] ]]; then
          resourceStaticFields+=" ${staticField}"
      fi
    done
    for jqField in $(jq -r ".resources[${i}].jqFields[].name" "${templateFile}"); do
      if [[ ! " ${resourceJqFields[*]} " =~ [[:space:]]${jqField}[[:space:]] ]]; then
          resourceJqFields+=" ${jqField}"
      fi
    done
  done

  echo "ICN,${patientFields// /,}Resource${resourceStaticFields// /,}${resourceJqFields// /,}" > "${outputFile}"


  TOKEN=$(new-ccg-token "${clientId}" "${clientSecret}" "${audience}" "${oauthUrl}" "${scope}" "${launch}")

  # Send the requests and create the spreadsheet rows
  for patientId in ${testPatients}; do
    request "${baseUrl}/Patient/${patientId}" "${workFile}" "${clientId}" "${clientSecret}" "${audience}" "${oauthUrl}" "${scope}" "${launch}" || return 1
    patientFieldValues="${patientId}"
    for field in ${patientFields}; do
      patientFieldValues+=","
      value=$(jq -r "$(jq -r ".patientFields[] | select(.name==\"${field}\") | .path" "${templateFile}")" "${workFile}")
      if [ "${value}" != "null" ]; then
        patientFieldValues+="${value//,/ }"  # Replace commas with spaces
      fi
    done

    for i in $(seq 0 $(($(jq '.resources | length' "${templateFile}")-1))); do
      resourceType=$(jq -r ".resources[${i}].type" "${templateFile}")
      staticFieldValues=""
      for field in ${resourceStaticFields}; do
        staticFieldValues+=","
        value="$(jq -r ".resources[] | select( .type==\"${resourceType}\") | ( .staticFields // [])[] | select(.name==\"${field}\") | .value" "${templateFile}")"
        if [ "${value}" != "null" ]; then
          staticFieldValues+="${value//,/ }"  # Replace commas with spaces
        fi
      done
      createSpreadsheetRowsForResource "${resourceType}" "${templateFile}" "${outputFile}" "${workFile}" "${baseUrl}" "${patientId}" "${patientFieldValues},${resourceType}${staticFieldValues}" "${resourceJqFields}" "${clientId}" "${clientSecret}" "${audience}" "${oauthUrl}" "${scope}" "${launch}"
    done
  done

}

createSpreadsheetRowsForResource() {
  local resourceType="${1}" templateFile="${2}" outputFile="${3}" workFile="${4}" baseUrl="${5}" patientId="${6}" rowNonResourceJqFields="${7}" resourceJqFields="${8}" clientId="${9}" clientSecret="${10}" audience="${11}" oauthUrl="${12}" scope="${13}" launch="${14}"
  local jqFieldValues url numRecords
  declare -A jqFieldValues

  url="${baseUrl}/${resourceType}?patient=${patientId}"
  while [ -n "${url:-}" ]; do
    jqFieldValues=()
    request "${url}" "${workFile}" "${clientId}" "${clientSecret}" "${audience}" "${oauthUrl}" "${scope}" "${launch}" || return 1
    unset url

    numRecords=$(jq -r '.entry | length' "${workFile}")

    if [ "${numRecords}" -eq 0 ]; then
      log "INFO" "No ${resourceType} resources found for patient ${patientId}"
      continue
    fi

    for jqField in ${resourceJqFields}; do
      if [[ " $(jq -r ".resources[] | select( .type==\"${resourceType}\" ) | .jqFields[].name" "${templateFile}" | tr '\n' ' ')" =~ [[:space:]]${jqField}[[:space:]] ]]; then
        jqFieldValues["${jqField}"]=$(jq -r ".entry[].resource | $(jq -r ".resources[] | select(.type==\"${resourceType}\") | .jqFields[] | select(.name==\"${jqField}\") | .path" "${templateFile}")" "${workFile}")
      fi
    done


    for i in $(seq 1 ${numRecords}); do
      row="${rowNonResourceJqFields}"
      for jqField in ${resourceJqFields}; do
        if [[ " $(jq -r " .resources[] | select( .type==\"${resourceType}\" ) | .jqFields[].name" "${templateFile}" | tr '\n' ' ')" =~ [[:space:]]${jqField}[[:space:]] ]]; then
          row+=",$(echo "${jqFieldValues[${jqField}]}" | sed -n "${i} p" | tr ',' ' ')"
        else
          row+=","
        fi
      done
      echo "${row}" >> "${outputFile}"
    done

    url=$(jq -r '.link[]? | select( .relation=="next" ) | .url' "${workFile}")
  done
}

request() {
  local url="${1}" workFile="${2}" clientId="${3}" clientSecret="${4}" audience="${5}" oauthUrl="${6}" scope="${7}" launch="${8}"

  log "INFO" "Requesting ${url}"
  if [ '200' != "$(curl -s -o "${workFile}" -w "%{http_code}" -H "Authorization: Bearer $TOKEN" "${url}")" ]; then
    log "INFO" "Refreshing token"
    TOKEN=$(new-ccg-token "${clientId}" "${clientSecret}" "${audience}" "${oauthUrl}" "${scope}" "${launch}")
    if [ '200' != "$(curl -s -o "${workFile}" -w "%{http_code}" -H "Authorization: Bearer $TOKEN" "${url}")" ]; then
      log "ERROR" "Request to ${url} failed. Response:"
      cat "${workFile}" | jq
      return 1
    fi
  fi
}
