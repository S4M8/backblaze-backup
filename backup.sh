#!/usr/bin/env bash

# Backblaze B2 Backup Script using Docker
# Usage: ./backup.sh <zip_file_path> <bucket_name> [remote_filename]

set -e # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_info() {
  echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
  echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
  echo -e "${RED}[ERROR]${NC} $1"
}

# Check if required arguments are provided
if [ $# -lt 2 ]; then
  print_error "Usage: $0 <zip_file_path> <bucket_name> [remote_filename]"
  print_info "Example: $0 ./backup.zip my-backup-bucket"
  print_info "Example: $0 ./backup.zip my-backup-bucket backups/$(date +%Y%m%d)/backup.zip"
  exit 1
fi

ZIP_FILE="$1"
BUCKET_NAME="$2"
REMOTE_FILENAME="${3:-$(basename "$ZIP_FILE")}"

# Check if .env file exists
ENV_FILE=".env"
if [ ! -f "$ENV_FILE" ]; then
  print_error ".env file not found!"
  print_info "Please create a .env file with the following format:"
  echo "B2_APPLICATION_KEY_ID=your_key_id_here"
  echo "B2_APPLICATION_KEY=your_application_key_here"
  print_info "Make sure to add .env to your .gitignore file!"
  exit 1
fi

# Source environment variables
print_info "Loading environment variables from .env file..."
set -a # automatically export all variables
source "$ENV_FILE"
set +a

# Validate required environment variables
if [ -z "$B2_APPLICATION_KEY_ID" ] || [ -z "$B2_APPLICATION_KEY" ]; then
  print_error "Missing required environment variables!"
  print_info "Please ensure .env file contains:"
  echo "B2_APPLICATION_KEY_ID=your_key_id_here"
  echo "B2_APPLICATION_KEY=your_application_key_here"
  exit 1
fi

# Check if zip file exists
if [ ! -f "$ZIP_FILE" ]; then
  print_error "Zip file '$ZIP_FILE' not found!"
  exit 1
fi

# Check if Docker is available
if ! command -v docker &>/dev/null; then
  print_error "Docker is not installed or not in PATH!"
  exit 1
fi

# Get absolute path of zip file for Docker volume mounting
ZIP_FILE_ABS=$(realpath "$ZIP_FILE")
ZIP_FILE_DIR=$(dirname "$ZIP_FILE_ABS")
ZIP_FILE_NAME=$(basename "$ZIP_FILE_ABS")

print_info "Starting backup process..."
print_info "File: $ZIP_FILE_ABS"
print_info "Bucket: $BUCKET_NAME"
print_info "Remote path: $REMOTE_FILENAME"

# Pull the latest Backblaze B2 CLI Docker image
print_info "Pulling Backblaze B2 CLI Docker image..."
docker pull tianon/backblaze-b2:latest

# Authorize with B2
print_info "Authorizing with Backblaze B2..."
docker run --rm \
  -e B2_APPLICATION_KEY_ID="$B2_APPLICATION_KEY_ID" \
  -e B2_APPLICATION_KEY="$B2_APPLICATION_KEY" \
  -v "$ZIP_FILE_DIR:/data" \
  tianon/backblaze-b2:latest \
  b2 authorize-account "$B2_APPLICATION_KEY_ID" "$B2_APPLICATION_KEY"

if [ $? -ne 0 ]; then
  print_error "Failed to authorize with Backblaze B2!"
  exit 1
fi

print_info "Authorization successful!"

# Function to cleanup Docker resources
cleanup_docker() {
  print_info "Cleaning up Docker resources..."

  # Stop any running B2 containers (if any are stuck)
  RUNNING_CONTAINERS=$(docker ps --filter "ancestor=tianon/backblaze-b2:latest" -q)
  if [ ! -z "$RUNNING_CONTAINERS" ]; then
    print_info "Stopping running B2 containers..."
    docker stop $RUNNING_CONTAINERS
  fi

  # Remove any exited B2 containers
  EXITED_CONTAINERS=$(docker ps -a --filter "ancestor=tianon/backblaze-b2:latest" --filter "status=exited" -q)
  if [ ! -z "$EXITED_CONTAINERS" ]; then
    print_info "Removing exited B2 containers..."
    docker rm $EXITED_CONTAINERS
  fi

  # Clean up any dangling images (optional - commented out to preserve image for future use)
  # print_info "Cleaning up dangling images..."
  # docker image prune -f

  print_info "Docker cleanup completed."
}

# Set up trap for cleanup on script exit
trap cleanup_docker EXIT

# Upload the file
print_info "Uploading $ZIP_FILE_NAME to bucket $BUCKET_NAME..."
UPLOAD_RESULT=$(docker run --rm \
  -e B2_APPLICATION_KEY_ID="$B2_APPLICATION_KEY_ID" \
  -e B2_APPLICATION_KEY="$B2_APPLICATION_KEY" \
  -v "$ZIP_FILE_DIR:/data" \
  tianon/backblaze-b2:latest \
  sh -c "b2 authorize-account '$B2_APPLICATION_KEY_ID' '$B2_APPLICATION_KEY' && b2 upload-file '$BUCKET_NAME' '/data/$ZIP_FILE_NAME' '$REMOTE_FILENAME'" 2>&1)

UPLOAD_EXIT_CODE=$?

if [ $UPLOAD_EXIT_CODE -eq 0 ]; then
  print_info "✅ Backup completed successfully!"
  print_info "File uploaded to: b2://$BUCKET_NAME/$REMOTE_FILENAME"

  # Get file info for verification
  print_info "Verifying upload..."
  VERIFY_RESULT=$(docker run --rm \
    -e B2_APPLICATION_KEY_ID="$B2_APPLICATION_KEY_ID" \
    -e B2_APPLICATION_KEY="$B2_APPLICATION_KEY" \
    tianon/backblaze-b2:latest \
    sh -c "b2 authorize-account '$B2_APPLICATION_KEY_ID' '$B2_APPLICATION_KEY' && b2 ls '$BUCKET_NAME' '$REMOTE_FILENAME'" 2>/dev/null)

  if [ $? -eq 0 ] && [ ! -z "$VERIFY_RESULT" ]; then
    print_info "✅ Upload verified successfully!"
    echo "$VERIFY_RESULT"
  else
    print_warning "Could not verify upload, but upload appeared successful"
  fi

  # Manual cleanup before exit (in addition to trap)
  cleanup_docker

  print_info "🎉 Backup process completed successfully!"
  exit 0
else
  print_error "❌ Backup failed!"
  print_error "Error details: $UPLOAD_RESULT"

  # Cleanup will be handled by trap
  exit 1
fi
