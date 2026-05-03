#!/bin/bash
# Usage: source .scripts/configure.sh

# Get the absolute path of the directory containing this script
SCRIPT_DIR_CONFIGURE="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# --- Gemini CLI Installation/Update ---
if ! command -v npm &> /dev/null; then
  echo "Error: npm is not installed. Please install Node.js and npm to continue." >&2
  return 1
fi

echo "Checking for the latest Gemini CLI version..."
LATEST_VERSION=$(npm view @google/gemini-cli version)

if ! command -v gemini &> /dev/null; then
  echo "Gemini CLI not found. Installing the latest version ($LATEST_VERSION)..."
  sudo npm install -g @google/gemini-cli@latest
else
  # Extract version from `npm list`, which is more reliable than `gemini --version`
  INSTALLED_VERSION=$(npm list -g @google/gemini-cli --depth=0 2>/dev/null | grep '@google/gemini-cli' | sed 's/.*@//')
  if [ "$INSTALLED_VERSION" == "$LATEST_VERSION" ]; then
    echo "Gemini CLI is already up to date (version $INSTALLED_VERSION)."
  else
    echo "A new version of Gemini CLI is available."
    echo "Upgrading from version $INSTALLED_VERSION to $LATEST_VERSION..."
    sudo npm install -g @google/gemini-cli@latest
  fi
fi

ENV_FILE=".env"

# --- 1. Load Existing .env ---
if [ -f "$ENV_FILE" ]; then
  # echo "Loading configuration from $ENV_FILE..."
  set -a
  source "$ENV_FILE"
  set +a
else
  # echo "No .env file found. A new one will be generated."
  touch "$ENV_FILE"
fi

# --- Helper Function: Single Source of Truth ---
set_config() {
  local var_name="$1"
  local default_value="$2"
  
  if [ -z "${!var_name}" ]; then
    export "$var_name"="$default_value"
  else
    export "$var_name"
  fi
}

# --- 2. Git Configuration ---
git config --global user.email "aburdenko@yahoo.com"
git config --global user.name "Alex Burdenko"

# --- 3. Determine Project ID ---
if [ -z "$PROJECT_ID" ]; then
    # Try to find it in service account key if referenced in ENV
    if [ -n "$GOOGLE_APPLICATION_CREDENTIALS" ] && [ -f "$GOOGLE_APPLICATION_CREDENTIALS" ]; then
         EXTRACTED_ID=$(jq -r .project_id "$GOOGLE_APPLICATION_CREDENTIALS" 2>/dev/null)
         if [ -n "$EXTRACTED_ID" ] && [ "$EXTRACTED_ID" != "null" ]; then
            PROJECT_ID="$EXTRACTED_ID"
         fi
    fi
    
    # Fallback to gcloud config
    if [ -z "$PROJECT_ID" ]; then
        PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
    fi

    # Fallback to manual input (Prompting is unavoidable if ID is completely missing)
    if [ -z "$PROJECT_ID" ]; then
        echo "Project ID not set in .env or gcloud config."
        mapfile -t projects < <(gcloud projects list --format="value(projectId)" --sort-by=projectId --quiet)
        if [ ${#projects[@]} -eq 0 ]; then
             read -p "Enter Project ID manually: " PROJECT_ID
        else
             echo "Select a project:"
             select opt in "${projects[@]}"; do
                if [ -n "$opt" ]; then PROJECT_ID=$opt; break; fi
             done
        fi
    fi
    
    if [ -z "$PROJECT_ID" ]; then echo "ERROR: Project ID required."; return 1; fi
    set_config "PROJECT_ID" "$PROJECT_ID"
fi

set_config "GOOGLE_CLOUD_PROJECT" "$PROJECT_ID"

# --- 4. Define Defaults ---
set_config "REGION" "us-central1"
gcloud config set compute/region $REGION --quiet

if [ -z "$PROJECT_NUMBER" ]; then
    NUM=$(gcloud projects describe $PROJECT_ID --format="value(projectNumber)" --quiet)
    set_config "PROJECT_NUMBER" "$NUM"
fi

set_config "FUNCTION_SERVICE_ACCOUNT" "${PROJECT_ID}@appspot.gserviceaccount.com"
set_config "LOG_NAME" "extract_pipeline_log"

# DocAI & Buckets
set_config "GCS_DOCUMENT_URI" "gs://extract_pipeline_bucket"
set_config "DOCAI_LOCATION" "us"
set_config "PROCESSOR_ID" "faf306856e4fe9b7"
set_config "DOCAI_TIMEOUT" "7200"
set_config "PROCESSOR_VERSION_ID" "2cdafe7643d57775"

DEFAULT_SOURCE_BUCKET=$(echo $GCS_DOCUMENT_URI | sed 's#gs://##' | cut -d'/' -f1)
set_config "SOURCE_GCS_BUCKET" "$DEFAULT_SOURCE_BUCKET"
set_config "STAGING_GCS_BUCKET" "${PROJECT_ID}-staging"
set_config "DOCKER_REPO" "us-central1-docker.pkg.dev/${PROJECT_ID}/pipelines-repo"
set_config "GCS_OUTPUT_URI" "gs://${STAGING_GCS_BUCKET}/docai-output/"
set_config "GCS_RAG_TEXT_URI" "gs://${SOURCE_GCS_BUCKET}/rag-engine-source-texts/"

set_config "INDEX_DISPLAY_NAME" "extract_pipeline_bucket-store-index"
set_config "INDEX_ENDPOINT_DISPLAY_NAME" "extract_pipeline_bucket-vector-store-endpoint"
set_config "EMBEDDING_MODEL_NAME" "text-embedding-004"


# --- 5. Authentication Logic (Fixed) ---
USING_SERVICE_ACCOUNT=false

if [ -n "$GOOGLE_APPLICATION_CREDENTIALS" ] && [ -f "$GOOGLE_APPLICATION_CREDENTIALS" ]; then
    # Extract email
    SA_EMAIL=$(jq -r '.client_email' "$GOOGLE_APPLICATION_CREDENTIALS" 2>/dev/null)
    
    if [ -n "$SA_EMAIL" ] && [ "$SA_EMAIL" != "null" ]; then
        echo "Found Service Account: $SA_EMAIL"
        
        # Attempt 1: Standard silent activation
        # We redirect stderr to null to hide the "Endpoint Verification" error if it happens
        if gcloud auth activate-service-account "$SA_EMAIL" --key-file="$GOOGLE_APPLICATION_CREDENTIALS" --quiet >/dev/null 2>&1; then
             echo "Success: Authenticated as $SA_EMAIL"
             USING_SERVICE_ACCOUNT=true
        else
             # Attempt 2: Disable client certificate check explicitly in config and retry
             # echo "Retrying auth with client certificates disabled..."
             gcloud config set context_aware/use_client_certificate false --quiet >/dev/null 2>&1
             
             
             if gcloud auth activate-service-account "$SA_EMAIL" --key-file="$GOOGLE_APPLICATION_CREDENTIALS" --quiet; then
                 echo "Success: Authenticated as $SA_EMAIL (Client Certs Disabled)"
                 USING_SERVICE_ACCOUNT=true
             else
                 echo "ERROR: Service Account authentication failed." >&2
                 return 1
             fi
        fi
    fi
fi

# Fallback to User ADC if SA failed or missing
if [ "$USING_SERVICE_ACCOUNT" = false ]; then
    if ! gcloud auth application-default print-access-token &>/dev/null; then
        echo "Logging in user (ADC)..."
        if ! gcloud auth application-default login --no-launch-browser --quiet; then
             echo "ERROR: User login failed." >&2
             return 1
        fi
    fi
else
    gcloud projects add-iam-policy-binding kallogjeri-project-345114 \
        --member="serviceAccount:kallogjeri-project-345114@appspot.gserviceaccount.com" \
        --role="roles/cloudaicompanion.user" &>/dev/null;  
fi

gcloud services enable cloudaicompanion.googleapis.com --project=kallogjeri-project-345114 &>/dev/null;  

# --- 6. Infrastructure Setup ---
if [ ! -d ".venv/python3.12" ]; then
    echo "Setting up Python Environment..."
    if ! command -v jq &> /dev/null; then sudo apt-get update >/dev/null && sudo apt-get install -y jq >/dev/null; fi
    sudo apt-get install -y python3.12-venv >/dev/null
    /usr/bin/python3 -m venv .venv/python3.12
    
    # IAM Bindings
    VERTEX_AI_SA="service-$PROJECT_NUMBER@gcp-sa-aiplatform.iam.gserviceaccount.com"
    DOCAI_SA="service-$PROJECT_NUMBER@gcp-sa-documentai.iam.gserviceaccount.com"
    
    gcloud services enable documentai.googleapis.com aiplatform.googleapis.com picker.googleapis.com --quiet

    gcloud storage buckets add-iam-policy-binding gs://$SOURCE_GCS_BUCKET --member="serviceAccount:$VERTEX_AI_SA" --role="roles/storage.objectViewer" --quiet >/dev/null
    gcloud storage buckets add-iam-policy-binding gs://$STAGING_GCS_BUCKET --member="serviceAccount:$VERTEX_AI_SA" --role="roles/storage.objectViewer" --quiet >/dev/null
    gcloud storage buckets add-iam-policy-binding gs://$SOURCE_GCS_BUCKET --member="serviceAccount:$DOCAI_SA" --role="roles/storage.objectViewer" --quiet >/dev/null
    gcloud storage buckets add-iam-policy-binding gs://$STAGING_GCS_BUCKET --member="serviceAccount:$DOCAI_SA" --role="roles/storage.objectAdmin" --quiet >/dev/null

    if [ "$USING_SERVICE_ACCOUNT" = true ]; then
        MEMBER="serviceAccount:$SA_EMAIL"
    else
        CURRENT_USER=$(gcloud config get-value account --quiet)
        MEMBER="user:$CURRENT_USER"
    fi
    
    gcloud iam service-accounts add-iam-policy-binding "$FUNCTION_SERVICE_ACCOUNT" --member="$MEMBER" --role="roles/iam.serviceAccountUser" --project="$PROJECT_ID" --quiet >/dev/null
    gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="serviceAccount:$FUNCTION_SERVICE_ACCOUNT" --role="roles/aiplatform.user" --quiet >/dev/null
    gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="$MEMBER" --role="roles/aiplatform.user" --quiet >/dev/null

    # VS Code Extension
    CODE_EXEC="/opt/code-oss/bin/codeoss-cloudworkstations"
    if [ -f "$CODE_EXEC" ] && ! $CODE_EXEC --list-extensions | grep -q "emeraldwalk.runonsave"; then
         VSIX="/tmp/runonsave.vsix"
         curl -L -o "$VSIX" "https://www.vsixhub.com/go.php?post_id=519&app_id=65a449f8-c656-4725-a000-afd74758c7e6&s=v5O4xJdDsfDYE&link=https%3A%2F%2Fmarketplace.visualstudio.com%2F_apis%2Fpublic%2Fgallery%2Fpublishers%2Femeraldwalk%2Fvsextensions%2FRunOnSave%2F0.3.2%2Fvspackage" 2>/dev/null
         if command -v unzip &>/dev/null && unzip -t "$VSIX" &>/dev/null; then
             $CODE_EXEC --install-extension "$VSIX" >/dev/null
         fi
         rm -f "$VSIX"
    fi
fi

# --- 7. Activate Python & Install Deps ---
if type deactivate &>/dev/null; then deactivate; fi
source .venv/python3.12/bin/activate
pip install -r requirements.txt > /dev/null

# --- 8. Apps Script & Sidebar ---
#if [ "$USING_SERVICE_ACCOUNT" = false ] && command -v npm &> /dev/null; then
if command -v npm &> /dev/null; then
    if ! command -v clasp &> /dev/null; then 
        sudo npm install -g @google/clasp@latest --silent
        # Ensure the entry point is executable
        CLASP_PATH=$(which clasp)
        if [ -L "$CLASP_PATH" ]; then
            sudo chmod +x "$(readlink -f "$CLASP_PATH")"
        else
            sudo chmod +x "$CLASP_PATH"
        fi
    fi
    if ! clasp login --status &>/dev/null; then clasp login --no-localhost; fi
fi

if [ -n "$APP_SCRIPT_ID" ] && [ -f "apps-script/Sidebar.template.html" ]; then
    cp "apps-script/Sidebar.template.html" "apps-script/Sidebar.html"
    sed -i "s|__GCP_PROJECT_ID_PLACEHOLDER__|${PROJECT_ID}|g" "apps-script/Sidebar.html"
    sed -i "s|__GEMINI_API_KEY_PLACEHOLDER__|${GEMINI_API_KEY:-}|g" "apps-script/Sidebar.html"
    sed -i "s|__DATETIME_PLACEHOLDER__|$(TZ="America/New_York" date +"%Y-%m-%d %H:%M %Z")|g" "apps-script/Sidebar.html"
    echo "{\"scriptId\":\"$APP_SCRIPT_ID\", \"rootDir\": \"apps-script\"}" > .clasp.json
fi

# Final Check
if ! (return 0 2>/dev/null); then echo "ERROR: Source this script."; exit 1; fi

echo "Configuration complete."

unset GOOGLE_API_KEY GEMINI_API_KEY
alias gemini="gemini -m $GEMINI_MODEL_NAME"