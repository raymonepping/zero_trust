#!/bin/sh
set -e

MODELS="${OLLAMA_MODELS:-llama3.2 nomic-embed-text}"

# Start Ollama server in the background
ollama serve &
OLLAMA_PID=$!

# Wait until the API is ready
echo "==> Waiting for Ollama to start..."
until curl -sf http://localhost:11434/api/tags > /dev/null 2>&1; do
  sleep 1
done
echo "==> Ollama is ready."

# Pull each model if not already present
for model in $MODELS; do
  if ollama list | grep -q "^${model}"; then
    echo "==> Model '${model}' already present, skipping."
  else
    echo "==> Pulling model: ${model}"
    ollama pull "${model}"
  fi
done

echo "==> All models ready."

# Keep the container alive by waiting on the server process
wait $OLLAMA_PID
