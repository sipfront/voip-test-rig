# jambonz websocket application that bridges a call to the OpenAI Realtime API.
# The feature-server calls this app (ws://voicebot:3000/openai-s2s); it returns
# the `llm` verb with the system prompt read from system-prompt.md.
ARG NODE_TAG=20-alpine
FROM node:${NODE_TAG}

WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev

COPY app.js ./
COPY lib ./lib
# Default prompt baked in; docker-compose mounts ./voicebot/system-prompt.md over
# it so admins can edit the prompt without rebuilding (read live per call).
COPY system-prompt.md ./

EXPOSE 3000
CMD ["node", "app.js"]
