#!/bin/bash

# Cloud Run Deployment Script for AI Dashboard

set -e

echo "Starting deployment to Google Cloud Run..."

# 1. Check for gcloud CLI
if ! command -v gcloud &> /dev/null; then
    echo "Error: 'gcloud' CLI is not installed."
    echo "Please install it from: https://cloud.google.com/sdk/docs/install"
    exit 1
fi

# 2. Configuration
PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
if [ -z "$PROJECT_ID" ]; then
    echo "No default Google Cloud project set."
    read -p "Enter your Google Cloud Project ID: " INPUT_PROJECT_ID
    if [ -z "$INPUT_PROJECT_ID" ]; then
        echo "Project ID is required."
        exit 1
    fi
    PROJECT_ID=$INPUT_PROJECT_ID
    gcloud config set project $PROJECT_ID
fi
echo "Using Project ID: $PROJECT_ID"

# Prompt for Service Name
read -p "Enter Cloud Run Service Name (default: ai-dashboard): " INPUT_APP_NAME
APP_NAME=${INPUT_APP_NAME:-ai-dashboard}
echo "Target Service: $APP_NAME"

# Prompt for Region
read -p "Enter Region (default: us-central1): " INPUT_REGION
REGION=${INPUT_REGION:-us-central1}
echo "Target Region: $REGION"

IMAGE_TAG="gcr.io/$PROJECT_ID/$APP_NAME"

# 3. Server-side API Keys
echo ""
echo "Configuration: Server-side environment variables"
echo "These keys are set as Cloud Run env vars (NOT baked into the build)."

# Try to load from .env.local
if [ -f .env.local ]; then
    source .env.local
fi

if [ -z "$GEMINI_API_KEY" ]; then
    read -p "Enter Gemini API Key (GEMINI_API_KEY): " GEMINI_API_KEY
fi

if [ -z "$TAVILY_API_KEY" ]; then
    read -p "Enter Tavily API Key (TAVILY_API_KEY): " TAVILY_API_KEY
fi

if [ -z "$SESSION_SECRET" ]; then
    SESSION_SECRET=$(openssl rand -hex 32)
    echo "Generated SESSION_SECRET: $SESSION_SECRET"
fi

if [ -z "$AUTH_PASSWORD_HASH" ]; then
    read -sp "Enter login password (will be hashed): " AUTH_PASSWORD
    echo ""
    AUTH_PASSWORD_HASH=$(node -e "import('bcryptjs').then(b=>b.default.hash('$AUTH_PASSWORD',12).then(console.log))")
    echo "Generated password hash."
fi

AUTH_USERNAME=${AUTH_USERNAME:-admin}

if [ -z "$API_TOKEN" ]; then
    read -p "Enter Worker API Token (API_TOKEN): " API_TOKEN
fi

# 4. Build & Push Image
echo ""
echo "Submitting build to Cloud Build..."

gcloud builds submit --tag $IMAGE_TAG .

# 5. Deploy to Cloud Run with server-side env vars
echo ""
echo "Deploying to Cloud Run..."

gcloud run deploy $APP_NAME \
    --image $IMAGE_TAG \
    --platform managed \
    --region $REGION \
    --allow-unauthenticated \
    --port 8080 \
    --set-env-vars "GEMINI_API_KEY=$GEMINI_API_KEY" \
    --set-env-vars "TAVILY_API_KEY=$TAVILY_API_KEY" \
    --set-env-vars "SESSION_SECRET=$SESSION_SECRET" \
    --set-env-vars "AUTH_USERNAME=$AUTH_USERNAME" \
    --set-env-vars "AUTH_PASSWORD_HASH=$AUTH_PASSWORD_HASH" \
    --set-env-vars "NODE_ENV=production" \
    --set-env-vars "API_TOKEN=$API_TOKEN"

echo ""
echo "Deployment Complete!"
