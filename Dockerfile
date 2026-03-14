# Stage 1: Build frontend
FROM node:20-alpine AS build
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm ci
COPY . .
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
