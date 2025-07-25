# Use a slim image as we are not building inside the container
FROM python:3.11-slim-bookworm

# Set environment variables for non-interactive installs
ENV PYTHONDONTWRITEBYTECODE 1
ENV PYTHONUNBUFFERED 1
ENV DEBIAN_FRONTEND=noninteractive

# Install runtime dependencies (kubectl) using the official Kubernetes APT repository
# This is the most robust method and avoids SSL issues with direct curl downloads.
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates gnupg curl && \
    # Add Kubernetes APT repository GPG key
    mkdir -p /etc/apt/keyrings && \
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.28/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg && \
    # Add the repository to the sources list
    echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.28/deb/ /' | tee /etc/apt/sources.list.d/kubernetes.list && \
    # Update apt list again and install kubectl
    apt-get update && \
    apt-get install -y --no-install-recommends kubectl && \
    # Clean up to keep the image small
    apt-get purge -y --auto-remove gnupg curl && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Copy the application source code
COPY main.py .
COPY web_server.py .
COPY templates/ templates/
COPY entrypoint.sh .

# CRITICAL STEP: Copy the pre-built site-packages from the local venv.
# This assumes './build.sh' has been run successfully on the host machine.
# This directory contains all dependencies, including the compiled Rust module.
COPY venv/lib/python3.11/site-packages/ /usr/local/lib/python3.11/site-packages/

# Make entrypoint executable
RUN chmod +x entrypoint.sh

# Expose the web server port
EXPOSE 5000

# Set the entrypoint
ENTRYPOINT ["/app/entrypoint.sh"]

# Default command to run the web server
CMD ["web"]