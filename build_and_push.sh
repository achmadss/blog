#!/bin/bash

set -e

# Customize these
IMAGE_NAME="novan921/blog"
TAG="latest"

echo "🐳 Building Docker image..."
docker build -t $IMAGE_NAME:$TAG .

echo "🔑 Logging in to Docker Hub..."
docker login

echo "📤 Pushing image to Docker Hub..."
docker push $IMAGE_NAME:$TAG

echo "✅ Done! Image pushed: $IMAGE_NAME:$TAG"
