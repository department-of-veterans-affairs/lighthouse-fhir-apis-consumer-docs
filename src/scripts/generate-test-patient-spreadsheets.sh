#!/usr/bin/env bash
set -euo pipefail
export WORK=$(mktemp -p /tmp -d work.XXXX)

main() {
  local preSubstitutionTemplate="${1}" outputXlsx="${2}"
  TEMPLATE_FILE=$(mktemp -p "${WORK:-/tmp}")
  TMP_OUTPUT_CSV="${WORK}/$(basename "${outputXlsx}" | sed 's/\.xlsx$/.csv/')"
  log "INFO" "Generating test data spreadsheet for ${preSubstitutionTemplate} and outputting to ${outputXlsx}"
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

  generateCsv

  convertToXlsx "${outputXlsx}"

  log "INFO" "Done"
}

log () { echo "$(date --utc +%FT%TZ) [${1}] ${2}"; }

onExit() {
  rm -rf "$WORK"
}

request() {
  local url="${1}" curlResponse="${2}" patientId="${3}" statusCode

  log "INFO" "Requesting ${url}"
  statusCode=$(curl -s -o "${curlResponse}" -w "%{http_code}" -H "Authorization: Bearer $TOKEN" "${url}")
  if [ "200" == "${statusCode}" ]; then
    return
  fi
  if [ "401" == "${statusCode}" ]; then
    log "INFO" "Refreshing token and retrying ${url}"
    TOKEN=$(newToken "${patientId}")
    statusCode=$(curl -s -o "${curlResponse}" -w "%{http_code}" -H "Authorization: Bearer $TOKEN" "${url}")
  fi
  if [ "200" != "${statusCode}" ]; then
    log "ERROR" "Request to ${url} failed. Status code was ${statusCode}."
    exit 1
  fi
}

generateCsv() {
  local curlResponse baseUrl patientFields resourceFields patientFieldValues resourceFieldValues
  curlResponse=$(mktemp -p "${WORK:-/tmp}")
  baseUrl=$(jq -r '.baseUrl' "${TEMPLATE_FILE}")

  patientFields=()
  resourceFields=()

  for resourceType in $(jq -r ".resources[].type" "${TEMPLATE_FILE}" | tr '\n' ' '); do
    for field in $(jq -r ".resources[] | select( .type==\"${resourceType}\").fields[].name" "${TEMPLATE_FILE}"); do
      if [[ "${resourceType}" == "Patient" ]]; then
        patientFields+=" ${field}"
      elif [[ ! " ${resourceFields[*]} " =~ [[:space:]]${field}[[:space:]] ]]; then
        resourceFields+=" ${field}"
      fi
    done
  done

  if [ -n "${patientFields}" ]; then
    patientFields=${patientFields:1} # Remove leading space
  fi

  echo "${patientFields// /,},Resource${resourceFields// /,}" > "${TMP_OUTPUT_CSV}"

  # Send the requests and create the spreadsheet rows
  for patientId in $(jq -r '.patientIds[]' "${TEMPLATE_FILE}"); do
    TOKEN=$(newToken "${patientId}")

    # Get the Patient field values. These will appear on every row for this patient.
    request "${baseUrl}/Patient/${patientId}" "${curlResponse}" "${patientId}"
    patientFieldValues=""
    for field in ${patientFields}; do
      patientFieldValues+=","
      configFieldObject=$(jq -r ".resources[] | select( .type==\"Patient\" ).fields[] | select(.name==\"${field}\")" "${TEMPLATE_FILE}")
      value=$(fieldValueFromRead "${configFieldObject}" "${curlResponse}")
      if [ "${value}" != "null" ]; then
        patientFieldValues+="\"${value}\""
      fi
    done

    if [ -n "${patientFieldValues}" ]; then
      patientFieldValues=${patientFieldValues:1} # Remove leading comma
    fi

    for resourceType in $(jq -r ".resources[] | select( .type!=\"Patient\" ).type" "${TEMPLATE_FILE}" | tr '\n' ' '); do
      createSpreadsheetRowsForResource "${resourceType}" "${curlResponse}" "${patientId}" "${patientFieldValues}" "${resourceFields}"
    done
  done
}

createSpreadsheetRowsForResource() {
  local resourceType="${1}" curlResponse="${2}" patientId="${3}" patientFieldValues="${4}" resourceFields="${5}" baseUrl resourceFieldValues url numRecords configFieldObject
  baseUrl=$(jq -r '.baseUrl' "${TEMPLATE_FILE}")
  declare -A resourceFieldValues

  url="${baseUrl}/${resourceType}?patient=${patientId}"
  while [ -n "${url:-}" ]; do
    resourceFieldValues=()
    request "${url}" "${curlResponse}" "${patientId}"
    unset url

    numRecords=$(jq -r '.entry | length' "${curlResponse}")

    if [ ! "${numRecords}" -gt 0 ]; then
      log "INFO" "No ${resourceType} resources found for patient ${patientId}"
      continue
    fi

    for fieldName in $(jq -r ".resources[] | select( .type==\"${resourceType}\" ).fields[].name" "${TEMPLATE_FILE}" | tr '\n' ' '); do
      configFieldObject="$(jq -r ".resources[] | select( .type==\"${resourceType}\" ).fields[] | select( .name==\"${fieldName}\" )" "${TEMPLATE_FILE}" | tr '\n' ' ')"
      resourceFieldValues["${fieldName}"]=$(fieldValuesFromSearch "${configFieldObject}" "${curlResponse}" "${numRecords}")
    done

    for i in $(seq 1 ${numRecords}); do
      row="${patientFieldValues},${resourceType}"
      for fieldName in ${resourceFields}; do
        if [[ " $(jq -r " .resources[] | select( .type==\"${resourceType}\" ) | .fields[].name" "${TEMPLATE_FILE}" | tr '\n' ' ')" =~ [[:space:]]${fieldName}[[:space:]] ]]; then
          row+=",\"$(echo "${resourceFieldValues[${fieldName}]}" | sed -n "${i} p")\""
        else
          row+=","
        fi
      done
      echo "${row}" >> "${TMP_OUTPUT_CSV}"
    done

    url=$(jq -r '.link[]? | select( .relation=="next" ) | .url' "${curlResponse}")
  done
}

fieldValueFromRead() {
  local configFieldObject="${1}" curlResponse="${2}"
  if echo "${configFieldObject}" | jq --exit-status '.jqQuery' >/dev/null; then
    jq -r "$(echo "${configFieldObject}" | jq -r '.jqQuery')" "${curlResponse}"
  elif echo "${configFieldObject}" | jq --exit-status '.staticValue' >/dev/null; then
    echo "${configFieldObject}" | jq -r '.staticValue'
  else
    log "ERROR" "No \"jqQuery\" or \"staticValue\" found for field: $(echo "${configFieldObject}" | jq -r '.name'))"
    exit 1
  fi
}

fieldValuesFromSearch() {
  local configFieldObject="${1}" curlResponse="${2}" numRecords="${3}" staticValue staticValueReplicated
  if echo "${configFieldObject}" | jq --exit-status '.jqQuery' >/dev/null; then
    jq -r ".entry[].resource | $(echo "${configFieldObject}" | jq -r '.jqQuery')" "${curlResponse}"
  elif echo "${configFieldObject}" | jq --exit-status '.staticValue' >/dev/null; then
    staticValue="$(echo "${configFieldObject}" | jq -r '.staticValue')"
    staticValueReplicated="${staticValue}"
    # Return rows of the same static value, one for each resource entry so they can be processed the same as jqQuery values
    for i in $(seq 1 $((${numRecords}-1))); do
      staticValueReplicated+=$(printf "\n%s" "${staticValue}")
    done
    echo "${staticValueReplicated}"
  else
    log "ERROR" "No \"jqQuery\" or \"staticValue\" found for field: $(echo "${configFieldObject}" | jq -r '.name'))"
    exit 1
  fi
}

convertToXlsx() {
  local outputXlsx="${1}"

  log "INFO" "Converting csv to xlsx"
  libreoffice --headless --convert-to xlsx --outdir "$(dirname "${outputXlsx}")" "${TMP_OUTPUT_CSV}"
}

newToken() {
  local patientId="${1}"
  case "$(jq -r '.authentication.type' "${TEMPLATE_FILE}")" in
    "ccg")
      newCcgToken "${patientId}"
      ;;
    *)
      log "ERROR" "Unsupported authentication type in template file: $(jq -r '.authentication.type' "${TEMPLATE_FILE}")"
      exit 1
      ;;
  esac
}

newCcgToken() {
  local launchPatient="${1}" clientId clientSecret audience oauthUrl
  clientId="$(jq -r '.authentication.clientId' "${TEMPLATE_FILE}")"
  clientSecret="$(jq -r '.authentication.clientSecret' "${TEMPLATE_FILE}")"
  audience="$(jq -r '.authentication.audience' "${TEMPLATE_FILE}")"
  oauthUrl="$(jq -r '.authentication.oauthUrl' "${TEMPLATE_FILE}")"
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