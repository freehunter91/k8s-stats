# Stage 1: Build Environment - Compiles the Rust module
# Use the full python image which includes build tools, reducing apt dependencies.
FROM python:3.12-bookworm AS builder

# Set environment variables for non-interactive installs
ENV PYTHONDONTWRITEBYTECODE 1
ENV PYTHONUNBUFFERED 1
ENV DEBIAN_FRONTEND=noninteractive

# Install Rust toolchain
# This curl command is generally very reliable.
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"

# Set working directory
WORKDIR /app

# Copy dependency definitions
COPY requirements.txt .
COPY rust_analyzer/ rust_analyzer/

# Install Python dependencies
RUN pip install --no-cache-dir -r requirements.txt

# Build the Rust accelerator module
RUN maturin build --release --strip --manifest-path rust_analyzer/Cargo.toml


# Stage 2: Final Production Image
FROM python:3.12-slim-bookworm

# Set environment variables
ENV PYTHONDONTWRITEBYTECODE 1
ENV PYTHONUNBUFFERED 1
ENV DEBIAN_FRONTEND=noninteractive

# Install kubectl using the official Kubernetes APT repository (most reliable method)
# This entire block is a single RUN command to optimize layers and cleanup.
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

# Copy installed Python packages and the built Rust wheel from the builder stage
COPY --from=builder /usr/local/lib/python3.12/site-packages/ /usr/local/lib/python3.12/site-packages/
COPY --from=builder /app/rust_analyzer/target/wheels/*.whl .

# Install the Rust wheel and then remove it
RUN pip install --no-cache-dir *.whl && rm *.whl

# Copy the application source code
COPY main.py .
COPY web_server.py .
COPY templates/ templates/
COPY entrypoint.sh .

# Make entrypoint executable
RUN chmod +x entrypoint.sh

# Expose the web server port
EXPOSE 5000

# Set the entrypoint
ENTRYPOINT ["/app/entrypoint.sh"]

# Default command to run the web server
CMD ["web"]
