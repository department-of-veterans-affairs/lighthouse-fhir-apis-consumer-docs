#!/usr/bin/env bash
set -euo pipefail
if [ "${DEBUG:=false}" == "true" ]; then set -x; fi
export WORK=$(mktemp -p /tmp -d work.XXXX)

main() {
  local preSubstitutionTemplate="${1}" outputXlsx="${2}" tmpOutputCsv
  TEMPLATE_FILE=$(mktemp -p "${WORK:-/tmp}")
  tmpOutputCsv="${WORK}/$(basename "${outputXlsx}" | sed 's/\.xlsx$/.csv/')"
  log "INFO" "Generating curled test data spreadsheet for ${preSubstitutionTemplate} and outputting to ${outputXlsx}"
  trap "onExit" EXIT

  if [ ! -f "${preSubstitutionTemplate}" ]; then
    log "ERROR" "${preSubstitutionTemplate} does not exist."
    return 1
  fi

  if ! jq -e . "${preSubstitutionTemplate}" >/dev/null 2>&1; then
    log "ERROR" "${preSubstitutionTemplate} is not valid json."
    return 1
  fi

  if ! command -v libreoffice &> /dev/null; then
    log "ERROR" "libreoffice is not installed. Please install libreoffice to use this script."
    exit 1
  fi

  log "INFO" "Performing environment substitution on ${preSubstitutionTemplate}"
  envsubst < "${preSubstitutionTemplate}" > "${TEMPLATE_FILE}"

  generateCsv "${tmpOutputCsv}"

  convertToXlsx "${tmpOutputCsv}" "${outputXlsx}"

  log "INFO" "Done"
}

log () { echo "$(date --utc +%FT%TZ) [${1}] ${2}"; }

onExit() {
  rm -rf "$WORK"
}

request() {
  local url="${1}" curlResponse="${2}" patientId="${3}" statusCode

  log "INFO" "Requesting ${url}"
  if [ "200" != "$(curl -s -o "${curlResponse}" -w "%{http_code}" -H "Authorization: Bearer $TOKEN" "${url}")" ]; then
    log "INFO" "Refreshing token and retrying ${url}"
    TOKEN=$(new-token)
    statusCode=$(curl -s -o "${curlResponse}" -w "%{http_code}" -H "Authorization: Bearer $TOKEN" "${url}")
    if [ "200" != "${statusCode}" ]; then
      log "ERROR" "Request to ${url} failed. Status code was ${statusCode}."
      exit 1
    fi
  fi
}

generateCsv() {
  local outputCsv="${1}"
  local curlResponse baseUrl patientFields resourceStaticFields resourceJqFields patientFieldValues staticFieldValues
  curlResponse=$(mktemp -p "${WORK:-/tmp}")
  baseUrl=$(jq -r '.baseUrl' "${TEMPLATE_FILE}")

  patientFields=$(jq -r '.patientFields[].name' "${TEMPLATE_FILE}" | tr '\n' ' ')
  resourceStaticFields=()
  resourceJqFields=()

  for i in $(seq 0 $(($(jq '.resources | length' "${TEMPLATE_FILE}")-1))); do
    for staticField in $(jq -r ".resources[${i}].staticFields[].name" "${TEMPLATE_FILE}"); do
      if [[ ! " ${resourceStaticFields[*]} " =~ [[:space:]]${staticField}[[:space:]] ]]; then
          resourceStaticFields+=" ${staticField}"
      fi
    done
    for jqField in $(jq -r ".resources[${i}].jqFields[].name" "${TEMPLATE_FILE}"); do
      if [[ ! " ${resourceJqFields[*]} " =~ [[:space:]]${jqField}[[:space:]] ]]; then
          resourceJqFields+=" ${jqField}"
      fi
    done
  done

  echo "ICN,${patientFields// /,}Resource${resourceStaticFields// /,}${resourceJqFields// /,}" > "${outputCsv}"

  # Send the requests and create the spreadsheet rows
  for patientId in $(jq -r '.patientIds[]' "${TEMPLATE_FILE}"); do
    TOKEN=$(new-token "${patientId}")
    request "${baseUrl}/Patient/${patientId}" "${curlResponse}" "${patientId}"
    patientFieldValues="${patientId}"
    for field in ${patientFields}; do
      patientFieldValues+=","
      value=$(jq -r "$(jq -r ".patientFields[] | select(.name==\"${field}\") | .path" "${TEMPLATE_FILE}")" "${curlResponse}")
      if [ "${value}" != "null" ]; then
        patientFieldValues+="${value//,/ }"  # Replace commas with spaces
      fi
    done

    for i in $(seq 0 $(($(jq '.resources | length' "${TEMPLATE_FILE}")-1))); do
      resourceType=$(jq -r ".resources[${i}].type" "${TEMPLATE_FILE}")
      staticFieldValues=""
      for field in ${resourceStaticFields}; do
        staticFieldValues+=","
        value="$(jq -r ".resources[] | select( .type==\"${resourceType}\") | ( .staticFields // [])[] | select(.name==\"${field}\") | .value" "${TEMPLATE_FILE}")"
        if [ "${value}" != "null" ]; then
          staticFieldValues+="${value//,/ }"  # Replace commas with spaces
        fi
      done
      createSpreadsheetRowsForResource "${resourceType}" "${outputCsv}" "${curlResponse}" "${patientId}" "${patientFieldValues},${resourceType}${staticFieldValues}" "${resourceJqFields}"
    done
  done
}

createSpreadsheetRowsForResource() {
  local resourceType="${1}" outputCsv="${2}" curlResponse="${3}" patientId="${4}" rowNonResourceJqFields="${5}" resourceJqFields="${6}" baseUrl jqFieldValues url numRecords
  baseUrl=$(jq -r '.baseUrl' "${TEMPLATE_FILE}")
  declare -A jqFieldValues

  url="${baseUrl}/${resourceType}?patient=${patientId}"
  while [ -n "${url:-}" ]; do
    jqFieldValues=()
    request "${url}" "${curlResponse}" "${patientId}"
    unset url

    numRecords=$(jq -r '.entry | length' "${curlResponse}")

    if [ "${numRecords}" -eq 0 ]; then
      log "INFO" "No ${resourceType} resources found for patient ${patientId}"
      continue
    fi

    for jqField in ${resourceJqFields}; do
      if [[ " $(jq -r ".resources[] | select( .type==\"${resourceType}\" ) | .jqFields[].name" "${TEMPLATE_FILE}" | tr '\n' ' ')" =~ [[:space:]]${jqField}[[:space:]] ]]; then
        jqFieldValues["${jqField}"]=$(jq -r ".entry[].resource | $(jq -r ".resources[] | select(.type==\"${resourceType}\") | .jqFields[] | select(.name==\"${jqField}\") | .path" "${TEMPLATE_FILE}")" "${curlResponse}")
      fi
    done

    for i in $(seq 1 ${numRecords}); do
      row="${rowNonResourceJqFields}"
      for jqField in ${resourceJqFields}; do
        if [[ " $(jq -r " .resources[] | select( .type==\"${resourceType}\" ) | .jqFields[].name" "${TEMPLATE_FILE}" | tr '\n' ' ')" =~ [[:space:]]${jqField}[[:space:]] ]]; then
          row+=",$(echo "${jqFieldValues[${jqField}]}" | sed -n "${i} p" | tr ',' ' ')"
        else
          row+=","
        fi
      done
      echo "${row}" >> "${outputCsv}"
    done

    url=$(jq -r '.link[]? | select( .relation=="next" ) | .url' "${curlResponse}")
  done
}

convertToXlsx() {
  local inputCsv="${1}" outputXlsx="${2}"

  log "INFO" "Converting csv to xlsx"
  libreoffice --headless --convert-to xlsx --outdir "$(dirname "${outputXlsx}")" "${inputCsv}"
}

new-token() {
  local patientId="${1}"
  if [ "ccg" == "$(jq -r '.authentication.type' "${TEMPLATE_FILE}")" ]; then
    new-ccg-token "${patientId}"
  else
    log "ERROR" "Unsupported authentication type in template file: $(jq -r '.authentication.type' "${TEMPLATE_FILE}")"
    exit 1
  fi
}

new-ccg-token() {
  local launchPatient="${1}" clientId clientSecret audience oauthUrl
  clientId="$(jq -r '.authentication.clientId' "${TEMPLATE_FILE}")"
  clientSecret="$(jq -r '.authentication.clientSecret' "${TEMPLATE_FILE}")"
  audience="$(jq -r '.authentication.audience' "${TEMPLATE_FILE}")"
  oauthUrl="$(jq -r '.authentication.oauthUrl' "${TEMPLATE_FILE}")"
  launchPatient="$(jq -r '.authentication.launchPatient' "${TEMPLATE_FILE}")"
  bash <(curl -sH"Authorization: Bearer $GITHUB_TOKEN" "https://raw.githubusercontent.com/department-of-veterans-affairs/shanktopus/master/bin/system-authorization-token") \
    --client-id "${clientId}" \
    --client-secret "${clientSecret}" \
    --audience "${audience}" \
    --oauth-url "${oauthUrl}" \
    --scope "$(jq -r '.authentication.scopes' "${TEMPLATE_FILE}")" \
    --launch "{\"patient\":\"${launchPatient}\"}" \
    --print-token \
    lab \
    | jq -r '.access_token'
}

main $@