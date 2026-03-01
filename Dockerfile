# Stage 1: Build
FROM node:20-alpine AS build
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm ci
COPY . .

# Debug: show which env files are present
RUN ls -la .env* 2>/dev/null || echo "No .env files found"

# Ensure .env.local exists for Vite build
# .env.local may be excluded by *.local in .gitignore during gcloud upload
# Copy .env.production to .env.local as fallback if .env.local is missing
RUN if [ ! -f .env.local ] && [ -f .env.production ]; then \
      cp .env.production .env.local; \
      echo "Copied .env.production -> .env.local"; \
    fi

RUN npm run build

# Stage 2: Serve
FROM node:20-alpine
RUN npm install -g serve@14
WORKDIR /app
COPY --from=build /app/dist ./dist

# Cloud Run invokes the container with a PORT environment variable
ENV PORT=8080
EXPOSE 8080

# Use shell form to recognize the $PORT environment variable
CMD serve -s dist -l $PORT
