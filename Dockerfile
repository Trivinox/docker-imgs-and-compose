# ---- Build stage: install only production dependencies ----
FROM node:20.14.0-alpine3.20 AS deps

WORKDIR /app

# Copy manifests first to leverage Docker layer cache.
# The npm install layer is only rebuilt when package*.json changes.
COPY app/package.json app/package-lock.json* ./

RUN npm ci --omit=dev && npm cache clean --force

# ---- Runtime stage: minimal final image ----
FROM node:20.14.0-alpine3.20

# Run as a non-root user -- least-privilege principle
RUN addgroup -S appgroup && adduser -S appuser -G appgroup

WORKDIR /app

# Copy installed modules from the build stage
COPY --from=deps /app/node_modules ./node_modules

# Copy application source
COPY app/ .

USER appuser

EXPOSE 3000

CMD ["node", "app.js"]
