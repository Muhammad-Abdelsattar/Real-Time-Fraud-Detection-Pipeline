set -e
set -u
set -o pipefail

# These can be overridden by command-line flags.
GCP_PROJECT_ID=""              # REQUIRED
SERVICE_NAME=""                # REQUIRED
MODEL_PATH_IN_GCS=""           # REQUIRED: e.g., "gs://your-models-bucket/path/to/model/"

IMAGE_REPO_NAME="ml-services"      # Name of your Artifact Registry repository
IMAGE_TAG="latest"                 # The tag for the new container image


SOURCE_CODE_PATH="machine_learning/inference_service" # Path to the service code, relative to the mono-repo root

#Optional
REGION="us-central1"
SERVICE_ACCOUNT_NAME="cloud-run-ml-sa"
MIN_INSTANCES=0
MAX_INSTANCES=5
MEMORY="512Gi"
CPU="1"
CONCURRENCY=5
IS_PUBLIC="false" # Controls --allow-unauthenticated parameter

# help
usage() {
  echo "Usage: $0 -p <project_id> -s <service_name> -i <image_uri> -m <model_path> [options]"
  echo
  echo "Required arguments:"
  echo "  -p, --project-id           Google Cloud project ID."
  echo "  -s, --service-name           Name for the Cloud Run service."
  echo "  -m, --model-path-in-gcs      GCS path to the model artifact (e.g., gs://bucket/model/). Passed as ENV var."
  echo
  echo "Optional arguments:"
  echo "  -r, --region                 GCP region for the service. (Default: ${REGION})"
  echo "  --service-account-name       Name of the service account to use. (Default: ${SERVICE_ACCOUNT_NAME})"
  echo "  --min-instances              Min container instances. (Default: ${MIN_INSTANCES})"
  echo "  --max-instances              Max container instances. (Default: ${MAX_INSTANCES})"
  echo "  --memory                     Memory limit (e.g., 512Mi, 1Gi). (Default: ${MEMORY})"
  echo "  --cpu                        CPU limit (e.g., 1, 2). (Default: ${CPU})"
  echo "  --concurrency                Max concurrent requests per container. (Default: ${CONCURRENCY})"
  echo "  --public                     Make the service publicly accessible (--allow-unauthenticated)."
  echo "  -h, --help                   Display this help message."
  exit 1
}

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -p|--project-id) GCP_PROJECT_ID="$2"; shift ;;
        -s|--service-name) SERVICE_NAME="$2"; shift ;;
        -m|--model-path-in-gcs) MODEL_PATH_IN_GCS="$2"; shift ;;
        -r|--region) REGION="$2"; shift ;;
        --service-account-name) SERVICE_ACCOUNT_NAME="$2"; shift ;;
        --min-instances) MIN_INSTANCES="$2"; shift ;;
        --max-instances) MAX_INSTANCES="$2"; shift ;;
        --memory) MEMORY="$2"; shift ;;
        --cpu) CPU="$2"; shift ;;
        --concurrency) CONCURRENCY="$2"; shift ;;
        --public) IS_PUBLIC="true" ;;
        -h|--help) usage ;;
        *) echo "Unknown parameter passed: $1"; usage ;;
    esac
    shift
done

# Make sure the required args are provided
if [[ -z "${GCP_PROJECT_ID}" || -z "${SERVICE_NAME}" || -z "${MODEL_PATH_IN_GCS}" ]]; then
  echo " ERROR: Missing one or more required arguments." && echo && usage
fi

# Get the abolute path of the code
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
MONO_REPO_ROOT=$(dirname $(dirname "${SCRIPT_DIR}"))
export SERVICE_SOURCE_CODE_ABS_PATH="${MONO_REPO_ROOT}/${SOURCE_CODE_PATH}"

# Dynamically construct the full image URI for the new build
export GCR_IMAGE_URI="${REGION}-docker.pkg.dev/${GCP_PROJECT_ID}/${IMAGE_REPO_NAME}/${SERVICE_NAME}:${IMAGE_TAG}"

export SERVICE_ACCOUNT_EMAIL="${SERVICE_ACCOUNT_NAME}@${GCP_PROJECT_ID}.iam.gserviceaccount.com"

# deployment logic
echo ">>> Starting end-to-end deployment for service '${SERVICE_NAME}'..."


# Deployment logic
echo ">>> Starting Cloud Run deployment for service '${SERVICE_NAME}'..."
echo "    Project: ${GCP_PROJECT_ID}, Region: ${REGION}"

echo ">>> Enabling required GCP APIs..."
gcloud services enable \
  run.googleapis.com \
  storage-component.googleapis.com \
  iam.googleapis.com \
  artifactregistry.googleapis.com \
  cloudbuild.googleapis.com

echo ">>> Checking for Artifact Registry repository '${IMAGE_REPO_NAME}'..."
if gcloud artifacts repositories describe "${IMAGE_REPO_NAME}" --project="${GCP_PROJECT_ID}" --location="${REGION}" &>/dev/null; then
  echo "Artifact Registry repository already exists."
else
  echo "Repository not found. Creating a Docker repository..."
  gcloud artifacts repositories create "${IMAGE_REPO_NAME}" \
    --project="${GCP_PROJECT_ID}" \
    --repository-format="docker" \
    --location="${REGION}" \
    --description="Repository for ML service containers"
fi

# make sure that the service acc exists, if not, create a new one.
echo ">>> Checking for service account '${SERVICE_ACCOUNT_EMAIL}'..."
if gcloud iam service-accounts describe "${SERVICE_ACCOUNT_EMAIL}" &>/dev/null; then
  echo "Service account already exists."
else
  echo "Service account not found. Creating..."
  gcloud iam service-accounts create "${SERVICE_ACCOUNT_NAME}" \
    --display-name="Cloud Run ML Service Identity"
fi

# Grant permissions, the service needs to be able to READ model artifacts from GCS.
echo ">>> Verifying and granting IAM roles..."
ROLES_TO_GRANT=("roles/storage.objectViewer") 

for role in "${ROLES_TO_GRANT[@]}"; do
  echo "  - Checking role: ${role}"
  EXISTING_BINDING=$(gcloud projects get-iam-policy "${GCP_PROJECT_ID}" --flatten="bindings[].members" --format="value(bindings.role)" --filter="bindings.members:serviceAccount:${SERVICE_ACCOUNT_EMAIL}" | grep -w "${role}") || true
  if [[ -n "${EXISTING_BINDING}" ]]; then
    echo "    OK: Service account already has the role."
  else
    echo "    GRANTING: Role not found, adding it now..."
    gcloud projects add-iam-policy-binding "${GCP_PROJECT_ID}" --member="serviceAccount:${SERVICE_ACCOUNT_EMAIL}" --role="${role}" --condition=None > /dev/null
    echo "    SUCCESS: Role granted."
  fi
done


echo ">>> Deploying new revision for '${SERVICE_NAME}'..."
echo "    CPU: ${CPU}, Memory: ${MEMORY}, Concurrency: ${CONCURRENCY}"

# Handle public access flag
if [[ "${IS_PUBLIC}" == "true" ]]; then
  PUBLIC_ACCESS_FLAG="--allow-unauthenticated"
  echo "    Access: Public"
else
  PUBLIC_ACCESS_FLAG="--no-allow-unauthenticated"
  echo "    Access: Private (requires authentication)"
fi

gcloud run deploy "${SERVICE_NAME}" \
  --image "${GCR_IMAGE_URI}" \
  --service-account "${SERVICE_ACCOUNT_EMAIL}" \
  --project "${GCP_PROJECT_ID}" \
  --region "${REGION}" \
  --platform "managed" \
  --cpu "${CPU}" \
  --memory "${MEMORY}" \
  --concurrency "${CONCURRENCY}" \
  --min-instances "${MIN_INSTANCES}" \
  --max-instances "${MAX_INSTANCES}" \
  --set-env-vars="MODEL_PATH=${MODEL_PATH_IN_GCS}" \
  ${PUBLIC_ACCESS_FLAG}

SERVICE_URL=$(gcloud run services describe "${SERVICE_NAME}" --project="${GCP_PROJECT_ID}" --region="${REGION}" --platform="managed" --format="value(status.url)")

echo ""
echo ">>> Deployment successful!"
echo ">>> Service URL: ${SERVICE_URL}"