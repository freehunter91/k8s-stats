# Stage 1: Build Environment - Compiles the Rust module
# Use the full python image which includes build tools, reducing apt dependencies.
FROM python:3.12-bookworm AS builder

# Set environment variables for non-interactive installs
ENV PYTHONDONTWRITEBYTECODE 1
ENV PYTHONUNBUFFERED 1
ENV DEBIAN_FRONTEND=noninteractive

# Install common build tools that Rust might depend on
RUN apt-get update && \
    apt-get install -y --no-install-recommends build-essential pkg-config && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

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

# Install curl, then download and install kubectl directly (more robust against repo issues)
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl ca-certificates && \
    # Download kubectl binary (using a specific stable version, e.g., v1.30.2)
    # Check https://kubernetes.io/releases/ for the latest stable client version.
    curl -LO "https://dl.k8s.io/release/v1.30.2/bin/linux/amd64/kubectl" && \
    # Download the checksum file
    curl -LO "https://dl.k8s.io/release/v1.30.2/bin/linux/amd64/kubectl.sha256" && \
    # Verify the checksum
    echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check && \
    # Install kubectl
    install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl && \
    # Clean up
    rm kubectl kubectl.sha256 && \
    apt-get purge -y --auto-remove curl && \
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
