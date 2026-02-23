# Stage 1: Build
FROM node:20-alpine AS build
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm ci
COPY . .

# Define build arguments for API keys
ARG VITE_API_KEY
ARG VITE_TAVILY_API_KEY
ARG VITE_GOOGLE_SEARCH_API_KEY
ARG VITE_GOOGLE_SEARCH_CX
ARG VITE_API_BASE_URL
ARG VITE_API_TOKEN

# Set environment variables from build arguments
ENV VITE_API_KEY=$VITE_API_KEY
ENV VITE_TAVILY_API_KEY=$VITE_TAVILY_API_KEY
ENV VITE_GOOGLE_SEARCH_API_KEY=$VITE_GOOGLE_SEARCH_API_KEY
ENV VITE_GOOGLE_SEARCH_CX=$VITE_GOOGLE_SEARCH_CX
ENV VITE_API_BASE_URL=$VITE_API_BASE_URL
ENV VITE_API_TOKEN=$VITE_API_TOKEN

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
