# Docker Lab -- Build and Deploy with Docker Compose

## Overview

This lab containerizes the MEAN stack Node.js application using Docker and deploys it alongside a MongoDB database with Docker Compose. The goal is to replace the EC2-based deployment (covered by the Terraform lab) with a local, portable setup that mirrors production behavior inside containers.

---

## Prerequisites

Before starting, make sure the following tools are installed and running on your machine:

| Tool | Minimum version | Check |
|------|----------------|-------|
| Docker Engine | 24.x | `docker --version` |
| Docker Compose | v2 (plugin) | `docker compose version` |
| Docker account | Any free tier | [hub.docker.com](https://hub.docker.com) |

> **Note:** Docker Desktop for Windows or macOS ships with both Docker Engine and the Compose plugin. On Linux, install the `docker-compose-plugin` package separately.

---

## Project Structure

```
mean-deploy-terraform/
├── app/
│   ├── app.js          -- Express application entry point
│   ├── db.js           -- MongoDB connection module
│   └── package.json    -- npm manifest and dependencies
├── mongo-init/
│   └── init.js         -- MongoDB initialisation script (runs once)
├── logs/
│   └── containers.log  -- Captured container logs (sample)
├── Dockerfile          -- Multi-stage image build for the Node.js app
├── docker-compose.yaml -- Service definitions: app + MongoDB
└── .dockerignore       -- Files excluded from the build context
```

---

## Step 1 -- Write the Application

Three source files live under `app/`.

### `app/db.js`

Handles the database connection using Mongoose. It reads the URI from the `MONGO_URI` environment variable so the same image can connect to different MongoDB instances without rebuilding.

```js
const mongoose = require('mongoose');
const MONGO_URI = process.env.MONGO_URI || 'mongodb://localhost:27017/meandb';

async function connect() {
  await mongoose.connect(MONGO_URI);
  console.log('MongoDB connected:', MONGO_URI);
}

module.exports = { connect };
```

### `app/app.js`

Starts the Express server only after the database connection is established. If the connection fails, the process exits with a non-zero code -- Docker will restart the container.

### `app/package.json`

Declares two runtime dependencies: `express` and `mongoose`. No dev dependencies are needed for the running container.

---

## Step 2 -- Write the Dockerfile

The `Dockerfile` uses a **multi-stage build** to keep the final image lean.

```dockerfile
# Stage 1: install production dependencies
FROM node:20.14.0-alpine3.20 AS deps
WORKDIR /app
COPY app/package.json app/package-lock.json* ./
RUN npm ci --omit=dev && npm cache clean --force

# Stage 2: runtime image
FROM node:20.14.0-alpine3.20
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY app/ .
USER appuser
EXPOSE 3000
CMD ["node", "app.js"]
```

### Best practices applied

| Practice | Where applied |
|----------|--------------|
| Pin an exact image tag | `node:20.14.0-alpine3.20` -- reproducible builds |
| Use Alpine base | Smaller attack surface and image size (~50 MB vs ~900 MB with `node:20`) |
| Multi-stage build | `node_modules` are installed in stage 1; only the result is copied to stage 2 |
| `npm ci` instead of `npm install` | Installs the exact locked versions; fails if `package-lock.json` is missing |
| `--omit=dev` | Excludes development-only packages from the final image |
| `npm cache clean --force` | Removes the npm cache after install -- reduces layer size |
| Non-root user | `appuser` runs the process -- limits damage if the container is compromised |
| `EXPOSE` | Documents the port; required for `docker compose` port mapping to work correctly |
| `.dockerignore` | Excludes `node_modules`, `.git`, Terraform files, and docs from the build context |

---

## Step 3 -- Write `docker-compose.yaml`

The Compose file defines two services that communicate over a dedicated bridge network.

```yaml
services:
  app:
    build:
      context: .
      dockerfile: Dockerfile
    image: mean-stack-app:latest
    ports:
      - "3000:3000"
    environment:
      MONGO_URI: mongodb://appuser:apppassword@mongodb:27017/meandb
    depends_on:
      mongodb:
        condition: service_healthy
    networks:
      - mean-network

  mongodb:
    image: mongo:7.0.9
    volumes:
      - mongo-data:/data/db
      - ./mongo-init/init.js:/docker-entrypoint-initdb.d/init.js:ro
    healthcheck:
      test: ["CMD", "mongosh", "--quiet", "--eval", "db.adminCommand('ping').ok"]
      interval: 10s
      retries: 5
    networks:
      - mean-network

volumes:
  mongo-data:

networks:
  mean-network:
    driver: bridge
```

### Key decisions

- **Custom network `mean-network`:** both containers join the same bridge network. Docker's embedded DNS resolves `mongodb` to the MongoDB container IP automatically -- no hardcoded addresses needed.
- **Healthcheck on MongoDB:** the `app` service uses `depends_on: condition: service_healthy`. Docker Compose waits until `mongosh` can reach the database before starting the Node.js container, preventing connection errors on startup.
- **Named volume `mongo-data`:** data persists across `docker compose down` and `docker compose up` cycles. The volume is only removed with `docker compose down -v`.
- **Initialisation script `mongo-init/init.js`:** mounted read-only at `/docker-entrypoint-initdb.d/`. MongoDB runs every `.js` file in that directory once, on the first start. The script creates the `appuser` account used by the application.
- **`image:` tag on the `app` service:** naming the built image makes it easy to push to Docker Hub later without re-tagging.

---

## Step 4 -- Build and Run

```bash
# Build the Node.js image and start all services in detached mode
docker compose up --build -d
```

Expected output:

```
[+] Building 18.3s (12/12) FINISHED
 => [deps 1/3] FROM docker.io/library/node:20.14.0-alpine3.20
 => [deps 3/3] RUN npm ci --omit=dev && npm cache clean --force
 => [stage-1 4/4] COPY app/ .
 => exporting to image
[+] Running 3/3
 ✔ Network mean-deploy-terraform_mean-network  Created
 ✔ Container mean-mongodb                      Healthy
 ✔ Container mean-app                          Started
```

Verify the application is responding:

```bash
curl http://localhost:3000
# {"message":"MEAN Stack -- Node.js Application","hostname":"<container-id>","timestamp":"..."}

curl http://localhost:3000/health
# {"status":"ok"}
```

---

## Step 5 -- Capture Container Logs

```bash
# All services with timestamps
docker compose logs --timestamps

# Node.js app only, follow in real time
docker compose logs --timestamps --follow app

# MongoDB only
docker compose logs --timestamps mongodb
```

The file `logs/containers.log` contains a representative capture of the output from a successful run. Key lines to look for:

| Line | Meaning |
|------|---------|
| `Waiting for connections` (MongoDB) | The database is ready to accept connections |
| `Successful authentication` (MongoDB) | The application authenticated as `appuser` |
| `MongoDB connected:` (app) | Mongoose established the connection |
| `Server listening on port 3000` (app) | Express is accepting HTTP traffic |

---

## Step 6 -- Publish the Image to Docker Hub

### 6.1 Create a Docker Hub account

Go to [hub.docker.com](https://hub.docker.com) and sign up for a free account if you do not have one. Choose a **username** -- it becomes part of every image name you push.

### 6.2 Log in from the CLI

```bash
docker login
# Enter your Docker Hub username and password when prompted.
# A token is cached at ~/.docker/config.json for future commands.
```

### 6.3 Tag the image

Docker Hub requires images to be named `<username>/<repository>:<tag>`.

```bash
docker tag mean-stack-app:latest <your-dockerhub-username>/mean-stack-app:1.0.0
docker tag mean-stack-app:latest <your-dockerhub-username>/mean-stack-app:latest
```

### 6.4 Push both tags

```bash
docker push <your-dockerhub-username>/mean-stack-app:1.0.0
docker push <your-dockerhub-username>/mean-stack-app:latest
```

Expected output:

```
The push refers to repository [docker.io/<username>/mean-stack-app]
1.0.0: digest: sha256:abc123... size: 1234
latest: digest: sha256:abc123... size: 1234
```

### 6.5 Verify on Docker Hub

Open `https://hub.docker.com/r/<your-username>/mean-stack-app` in a browser. You should see both tags listed under the **Tags** tab.

### 6.6 Pull and test from Docker Hub

To confirm the published image works independently of the local build:

```bash
# Remove the local image first
docker rmi mean-stack-app:latest <your-dockerhub-username>/mean-stack-app:latest

# Update docker-compose.yaml: replace `build:` block with `image: <username>/mean-stack-app:latest`
# Then run:
docker compose up -d
```

---

## Useful Commands Reference

| Task | Command |
|------|---------|
| Build image | `docker compose build` |
| Start all services | `docker compose up -d` |
| Stop all services | `docker compose down` |
| Stop and remove volumes | `docker compose down -v` |
| View live logs | `docker compose logs -f` |
| List running containers | `docker ps` |
| Inspect a container | `docker inspect mean-app` |
| Open a shell in the app container | `docker exec -it mean-app sh` |
| Open a MongoDB shell | `docker exec -it mean-mongodb mongosh -u appuser -p apppassword meandb` |
| Check image size | `docker image ls mean-stack-app` |

---

## Troubleshooting

### App exits immediately with "Failed to connect to MongoDB"

The MongoDB healthcheck has not passed yet. Increase `start_period` in the `healthcheck` block or run `docker compose logs mongodb` to see why MongoDB is not starting.

### Port 3000 is already in use

Another process is listening on port 3000. Either stop it or change the host-side port in `docker-compose.yaml`:

```yaml
ports:
  - "3001:3000"   # Access the app at localhost:3001
```

### `npm ci` fails: "missing package-lock.json"

Run `npm install` locally inside the `app/` directory first to generate `package-lock.json`, commit it, and then rebuild.

### Docker Hub push returns "denied: access forbidden"

You are not logged in, or the repository name does not match your username. Run `docker login` and confirm the tag prefix matches your Docker Hub username exactly.
