#!/usr/bin/env bash
set -euo pipefail
if [ "${DEBUG:=false}" == "true" ]; then set -x; fi
export WORK=$(mktemp -p /tmp -d work.XXXX)
SCRIPT_DIR=$(dirname $(readlink -f $0))
source "${SCRIPT_DIR}/test-patient-spreadsheet-generator.sh"

UNSUCCESSFUL_APIS=()

: ${SLACK_CHANNEL:=vaapi-alerts-testing}

main() {
  if [ ! "true" == "${EXECUTE:-false}" ]; then
    log "INFO" "Skipping Generate Test Patient Spreadsheet Job as EXECUTE is set to false in ${ENVIRONMENT:-local}."
    return
  fi
  local chapiSpreadsheet=$(mktemp -p "${WORK}") gitBranch
  log "INFO" "Starting Generate Test Patient Spreadsheet Job..."
  trap "onExit" EXIT

  # Generate the new spreadsheets
  generateChapiTestDataSpreadsheet "${chapiSpreadsheet}"

  # Push the generated spreadsheets to GitHub
  if [ "true" == "${RELEASE:-false}" ]; then
    cd "${WORK}"
    git clone "https://github.com/department-of-veterans-affairs/${DOCUMENTATION_REPO}.git"
    cd "${DOCUMENTATION_REPO}"
    gitBranch=$(git branch -r | grep -o 'DOCS-.*-spreadsheet-updates' || true | head -n 1)
    if [ -z $gitBranch ]; then
      gitBranch="DOCS-$(date +%s)-spreadsheet-updates"
      git branch ${gitBranch}
    fi
    git checkout ${gitBranch}

    mkdir -p ./clinical-health-v0; mv "${chapiSpreadsheet}" "./clinical-health-v0/clinical-health-v0-test-patient-spreadsheet.csv"

    git add .
    if [ -z "$(git status --porcelain)" ]; then
      echo "No changes"
    else
      git add $(git status -s | grep "^ M" | cut -c4-)
      git commit -m "Generated Test Patient Spreadsheets"
      git push -u origin ${gitBranch}
      if ! $(ghPrList "${DOCUMENTATION_REPO}") | grep 'DOCS-.*-spreadsheet-updates' || true
      then
        ghPrCreate "${gitBranch}"
      fi
    fi
  else
    log "INFO" "Skipping GitHub push as RELEASE is set to false in ${ENVIRONMENT:-local}. Outputing csvs here instead."
    printCsv "${chapiSpreadsheet}" "clinical-health-v0-test-patient-spreadsheet.csv"
  fi

  if [ ${#UNSUCCESSFUL_APIS[@]} -ne 0 ]; then
    sendSlackErrorMessage "$(echo "${UNSUCCESSFUL_APIS[@]}" | tr ' ' ',')"
  exit 1
  fi
}

ghPrList() {
  curl -L \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${GH_TOKEN}" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/department-of-veterans-affairs/${DOCUMENTATION_REPO}/pulls"
}

ghPrCreate() {
  local gitBranch="${1}"
  curl -L \
    -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${GH_TOKEN}" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    https://api.github.com/repos/department-of-veterans-affairs/${DOCUMENTATION_REPO}/pulls \
    -d "\"{\"title\":\"Test Data Spreadsheet Changes\",\"head\":\"${gitBranch}\",\"base\":\"main\"}"
}

generateChapiTestDataSpreadsheet() {
  local outputFile="${1}"
  generateTestDataSpreadsheet "clinical-health-v0-r4" \
    "${outputFile}" \
    "${CHAPI_TEST_PATIENTS}" \
    "${OAUTH_CLIENT_CREDENTIALS_CLIENT_ID}" \
    "${OAUTH_CLIENT_CREDENTIALS_CLIENT_SECRET}" \
    "${CLINICAL_HEALTH_V0_R4_CLIENT_CREDENTIALS_AUDIENCE}" \
    "${CLINICAL_HEALTH_V0_R4_CLIENT_CREDENTIALS_TOKEN_URL//\/token/}" \
    "launch system/AllergyIntolerance.read system/Condition.read system/MedicationDispense.read system/MedicationRequest.read system/Observation.read system/Patient.read system/Practitioner.read" \
    "{\"patient\":\"${CLINICAL_HEALTH_V0_R4_SSOI_LAUNCH_PATIENT}\"}"
}

generateTestDataSpreadsheet() {
  local api="${1}" outputFile="${2}" testPatients="${3}" clientId="${4}" clientSecret="${5}" audience="${6}" oauthUrl="${7}" scope="${8}" launch="${9}" templateFile
  templateFile="${SCRIPT_DIR}/${api}-template.json"

  log "INFO" "Generating test data spreadsheet for ${api} using ${templateFile}"
  if ! generateTestPatientSpreadsheet "${api}" "${templateFile}" "${outputFile}" "${testPatients}" "${clientId}" "${clientSecret}" "${audience}" "${oauthUrl}" "${scope}" "${launch}"
  then
    log "ERROR" "Failed to generate test data spreadsheet for ${api}."
    UNSUCCESSFUL_APIS+=("$api")
    return
  fi
}

printCsv() {
  local csvFile="${1}" csvName="${2}"
  if [ -f "${csvFile}" ]; then
    echo
    echo "${csvName}:"
    cat "${csvFile}"
  fi
}

onExit() {
  rm -rf "$WORK"
  istio shutdown
}

main $@