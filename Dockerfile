# Stage 1: Build
FROM node:20-alpine AS builder

WORKDIR /app

COPY package*.json ./
RUN npm install

COPY src/ ./src/

# Stage 2: Production
FROM node:20-alpine

WORKDIR /app

COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/src ./src

RUN apk add --no-cache wget

ENV NODE_ENV=production

CMD ["node", "src/index.js"]
