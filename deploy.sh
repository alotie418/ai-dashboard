#!/bin/bash

# Cloud Run Deployment Script for AI Dashboard

set -e

echo "🚀 Starting deployment to Google Cloud Run..."

# 1. Check for gcloud CLI
if ! command -v gcloud &> /dev/null; then
    echo "❌ Error: 'gcloud' CLI is not installed."
    echo "Please install it from: https://cloud.google.com/sdk/docs/install"
    exit 1
fi

# 2. Configuration
PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
if [ -z "$PROJECT_ID" ]; then
    echo "⚠️  No default Google Cloud project set."
    read -p "Enter your Google Cloud Project ID: " INPUT_PROJECT_ID
    if [ -z "$INPUT_PROJECT_ID" ]; then
        echo "❌ Project ID is required."
        exit 1
    fi
    PROJECT_ID=$INPUT_PROJECT_ID
    gcloud config set project $PROJECT_ID
fi
echo "✅ Using Project ID: $PROJECT_ID"

# Prompt for Service Name (to allow overwriting existing)
read -p "Enter Cloud Run Service Name (default: ai-dashboard): " INPUT_APP_NAME
APP_NAME=${INPUT_APP_NAME:-ai-dashboard}
echo "✅ Target Service: $APP_NAME"

# Prompt for Region
read -p "Enter Region (default: us-central1): " INPUT_REGION
REGION=${INPUT_REGION:-us-central1}
echo "✅ Target Region: $REGION"

IMAGE_TAG="gcr.io/$PROJECT_ID/$APP_NAME"

# 3. API Keys Handling
echo ""
echo "🔑 Configuration: API Keys"
echo "These keys will be baked into the static build."

# Helper to read env var or prompt
get_key() {
    local var_name=$1
    local prompt_text=$2
    local current_val=${!var_name}
    
    if [ -z "$current_val" ]; then
        read -p "$prompt_text: " input_val
        eval "$var_name=\"$input_val\""
    else
        echo "$prompt_text: (Using generic env var)"
    fi
}

# Try to load from .env.local or .env if present
if [ -f .env.local ]; then
    source .env.local
elif [ -f .env ]; then
    source .env
fi

if [ -z "$VITE_API_KEY" ]; then
    read -p "Enter Gemini API Key (VITE_API_KEY): " VITE_API_KEY
fi

if [ -z "$VITE_TAVILY_API_KEY" ]; then
    read -p "Enter Tavily API Key (VITE_TAVILY_API_KEY): " VITE_TAVILY_API_KEY
fi

if [ -z "$VITE_GOOGLE_SEARCH_API_KEY" ]; then
    read -p "Enter Google Search API Key (VITE_GOOGLE_SEARCH_API_KEY, or press Enter to skip): " VITE_GOOGLE_SEARCH_API_KEY
fi

if [ -z "$VITE_GOOGLE_SEARCH_CX" ]; then
    read -p "Enter Google Search CX (VITE_GOOGLE_SEARCH_CX, or press Enter to skip): " VITE_GOOGLE_SEARCH_CX
fi

# 4. Build & Push Image (using Cloud Build)
echo ""
echo "🏗️  Submitting build to Cloud Build..."
echo "This may take a few minutes."

# Generate cloudbuild.yaml to pass build-args
cat > cloudbuild.yaml <<EOF
steps:
- name: 'gcr.io/cloud-builders/docker'
  args: [
    'build',
    '--build-arg', 'VITE_API_KEY=${VITE_API_KEY}',
    '--build-arg', 'VITE_TAVILY_API_KEY=${VITE_TAVILY_API_KEY}',
    '--build-arg', 'VITE_GOOGLE_SEARCH_API_KEY=${VITE_GOOGLE_SEARCH_API_KEY}',
    '--build-arg', 'VITE_GOOGLE_SEARCH_CX=${VITE_GOOGLE_SEARCH_CX}',
    '--build-arg', 'VITE_API_BASE_URL=${VITE_API_BASE_URL}',
    '--build-arg', 'VITE_API_TOKEN=${VITE_API_TOKEN}',
    '-t', '$IMAGE_TAG',
    '.'
  ]
images:
- '$IMAGE_TAG'
EOF

echo "📝 Generated temporary cloudbuild.yaml"
gcloud builds submit --config cloudbuild.yaml .
rm -f cloudbuild.yaml

# 5. Deploy to Cloud Run
echo ""
echo "🚀 Deploying to Cloud Run..."

gcloud run deploy $APP_NAME \
    --image $IMAGE_TAG \
    --platform managed \
    --region $REGION \
    --allow-unauthenticated \
    --port 8080

echo ""
echo "✅ Deployment Complete!"
