FROM node:20-alpine

# Install Docker CLI and Compose plugin inside the agent container
# docker-cli-compose provides the 'docker compose' subcommand on Alpine
RUN apk add --no-cache docker-cli docker-cli-compose bash

WORKDIR /usr/src/agent

COPY package.json package-lock.json* ./
RUN npm install --omit=dev

COPY src ./src
COPY config.json ./config.json

EXPOSE 3001

CMD ["node", "src/server.js"]
