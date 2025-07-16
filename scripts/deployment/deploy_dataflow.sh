set -e

set -u

set -o pipefail


GCP_PROJECT_ID=""
REGION="us-central1"
SERVICE_ACCOUNT_NAME="dataflow-sa"
GCS_BUCKET="" 
INPUT_TOPIC_ID="" 
MODEL_ENDPOINT_URL="" 


PIPELINE_PROJECT_PATH="data_pipelines/streaming"
JOB_NAME_PREFIX="fraud-detection-streaming"

# Here we decide if we want to update an existing pipeline or create a new one. If we want to update, the same of the new job MUST be 
# exactly the same as the one running at that time. That means when IS_UPDATE is "true", EXISTING_JOB_NAME_TO_UPDATE Must be provided.

IS_UPDATE="false"
EXISTING_JOB_NAME_TO_UPDATE=""

#This represents the directory containing the code to be deployed.
DIRECTORY_PATH="data_pipelines/streaming/fraud_detection_pipeline"


# Get the directory where this script is located.
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

MONO_REPO_ROOT=$(dirname $(dirname "${SCRIPT_DIR}"))

# The absolute path of the code directory
PIPELINE_ROOT_ABS_PATH="${MONO_REPO_ROOT}/${DIRECTORY_PATH}"

echo ">>> Deploying Pipeline From:  ${PIPELINE_ROOT_ABS_PATH}"
SETUP_FILE_PATH="${PIPELINE_ROOT_ABS_PATH}/setup.py"
MAIN_SCRIPT_PATH="${PIPELINE_ROOT_ABS_PATH}/main.py"


usage() {
  echo "Usage: $0 -p <project_id> -b <gcs_bucket> -t <topic_id> -m <model_endpoint_url> [options]"
  echo
  echo "Required arguments:"
  echo "  -p, --project-id           Google Cloud project ID."
  echo "  -b, --gcs-bucket             GCS bucket for staging and output."
  echo "  -t, --topic-id               Pub/Sub topic ID to read from."
  echo "  -m, --model-endpoint-url     URL of the deployed ML model."
  echo
  echo "Optional arguments:"
  echo "  -r, --region                 GCP region for the Dataflow job."
  echo "  -s, --service-account-name   The name of the service account, just the name not the whole service account (i.e. dataflow-sa only)"
  echo "  -u, --update                 Set this flag to update an existing job."
  echo "  -j, --job-name-to-update     The exact name of the job to update. (Required if -u is set)"
  echo "  -h, --help                   Display this help message."
  exit 1
}

# Parse argments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -p|--project-id) GCP_PROJECT_ID="$2"; shift ;;
        -b|--gcs-bucket) GCS_BUCKET="$2"; shift ;;
        -t|--topic-id) INPUT_TOPIC_ID="$2"; shift ;;
        -m|--model-endpoint-url) MODEL_ENDPOINT_URL="$2"; shift ;;
        -r|--region) REGION="$2"; shift ;;
        -s|--service-account-name) SERVICE_ACCOUNT_NAME="$2"; shift ;;
        -u|--update) IS_UPDATE="true" ;;
        -j|--job-name-to-update) EXISTING_JOB_NAME_TO_UPDATE="$2"; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown parameter passed: $1"; usage ;;
    esac
    shift
done


if [[ -z "${GCP_PROJECT_ID}" || -z "${GCS_BUCKET}" || -z "${INPUT_TOPIC_ID}" || -z "${MODEL_ENDPOINT_URL}" ]]; then
  echo " ERROR: Missing one or more required arguments."
  echo
  usage
fi


SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
MONO_REPO_ROOT=$(dirname $(dirname "${SCRIPT_DIR}"))
export PIPELINE_ROOT_ABS_PATH="${MONO_REPO_ROOT}/${PIPELINE_PROJECT_PATH}"
export SETUP_FILE_PATH="${PIPELINE_ROOT_ABS_PATH}/setup.py"
export MAIN_SCRIPT_PATH="${PIPELINE_ROOT_ABS_PATH}/main.py"
export SERVICE_ACCOUNT_EMAIL="${SERVICE_ACCOUNT_NAME}@${GCP_PROJECT_ID}.iam.gserviceaccount.com"
export INPUT_TOPIC_PATH="projects/${GCP_PROJECT_ID}/topics/${INPUT_TOPIC_ID}"
export STAGING_LOCATION="gs://${GCS_BUCKET}/${JOB_NAME_PREFIX}/staging/"
export TEMP_LOCATION="gs://${GCS_BUCKET}/${JOB_NAME_PREFIX}/temp/"
export OUTPUT_PATH="gs://${GCS_BUCKET}/raw_processed_transactions/"


if [[ "${IS_UPDATE}" == "true" ]]; then
  if [[ -z "${EXISTING_JOB_NAME_TO_UPDATE}" ]]; then
    echo " ERROR: When using --update (-u), you must provide a job name with --job-name-to-update (-j)."
    exit 1
  fi
  export JOB_NAME="${EXISTING_JOB_NAME_TO_UPDATE}"
  export UPDATE_FLAG="--update"
else
  export JOB_NAME="${JOB_NAME_PREFIX}-$(date +%Y%m%d-%H%M%S)"
  export UPDATE_FLAG=""
fi

echo ">>> Starting deployment with the following configuration:"
echo "    Project ID: ${GCP_PROJECT_ID}"
echo "    Region: ${REGION}"
echo "    GCS Bucket: ${GCS_BUCKET}"
echo "    Service Account: ${SERVICE_ACCOUNT_EMAIL}"
echo "    Deployment Mode: $([[ "$IS_UPDATE" == "true" ]] && echo "UPDATE" || echo "NEW DEPLOYMENT")"
echo "    Job Name: ${JOB_NAME}"
echo "-------------------------------------------------------------------"


#Enabling required GCP APIs
echo ">>> Enabling required GCP APIs..."

gcloud services enable \
  dataflow.googleapis.com \
  compute.googleapis.com \
  storage-component.googleapis.com \
  logging.googleapis.com \
  pubsub.googleapis.com \
  firestore.googleapis.com \
  run.googleapis.com


# Ensure service account exists, if not create a new one with th provided name.
echo ">>> Checking for service account '${SERVICE_ACCOUNT_EMAIL}'..."
if gcloud iam service-accounts describe "${SERVICE_ACCOUNT_EMAIL}" &>/dev/null; then
  echo "Service account already exists."
else
  echo "Service account not found. Creating..."
  gcloud iam service-accounts create "${SERVICE_ACCOUNT_NAME}" \
    --display-name="Dataflow Pipeline Worker" \
    --description="Service account for running Dataflow pipelines"
fi


# Granting the service account the required roles for the service to operate
echo ">>> Verifying and granting IAM roles...."

ROLES_TO_GRANT=(
  "roles/dataflow.worker" "roles/storage.objectAdmin" "roles/pubsub.admin"
  "roles/datastore.user" "roles/dataflow.admin" 
)

for role in "${ROLES_TO_GRANT[@]}"; do
  echo "  > Checking role: ${role}"
  EXISTING_BINDING=$(gcloud projects get-iam-policy "${GCP_PROJECT_ID}" \
    --flatten="bindings[].members" --format="value(bindings.role)" \
    --filter="bindings.members:serviceAccount:${SERVICE_ACCOUNT_EMAIL}" | grep -w "${role}") || true
  if [[ -n "${EXISTING_BINDING}" ]]; then
    echo "    OK: Service account already has the role."
  else
    echo "    GRANTING: Role not found, adding it now..."
    gcloud projects add-iam-policy-binding "${GCP_PROJECT_ID}" \
      --member="serviceAccount:${SERVICE_ACCOUNT_EMAIL}" --role="${role}" --condition=None > /dev/null
    echo "    SUCCESS: Role granted."
  fi
done


echo ">>> DEPLOYMENT MODE: $([[ "$IS_UPDATE" == "true" ]] && echo "UPDATE" || echo "NEW DEPLOYMENT")"
echo ">>> Deploying Dataflow job '${JOB_NAME}'..."

cd "${PIPELINE_ROOT_ABS_PATH}"


  python3 "${MAIN_SCRIPT_PATH}" \
  --runner DataflowRunner \
  --project "${GCP_PROJECT_ID}" \
  --region "${REGION}" \
  --job_name "${JOB_NAME}" \
  ${UPDATE_FLAG} \
  --service_account_email "${SERVICE_ACCOUNT_EMAIL}" \
  --staging_location "${STAGING_LOCATION}" \
  --temp_location "${TEMP_LOCATION}" \
  --subnetwork regions/us-central1/subnetworks/default \
  --ml_batch_size 100 \
  --window_duration_seconds 300 \
  --setup_file "${SETUP_FILE_PATH}" \
  --input_topic "${INPUT_TOPIC_PATH}" \
  --output_path "${OUTPUT_PATH}" \
  --model_endpoint_url "${MODEL_ENDPOINT_URL}"\
  --streaming 

echo ""
echo ">>>  Deployment command sent successfully!"
