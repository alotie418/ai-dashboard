# Stage 1: Build frontend
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

# Stage 2: Production server (Express + static files)
FROM node:20-alpine
WORKDIR /app

# Copy built frontend
COPY --from=build /app/dist ./dist

# Copy server files
COPY --from=build /app/server.js ./
COPY --from=build /app/server ./server

# Install production dependencies only
COPY package.json package-lock.json* ./
RUN npm ci --omit=dev

# Cloud Run invokes the container with a PORT environment variable
ENV PORT=8080
EXPOSE 8080

CMD ["node", "server.js"]
