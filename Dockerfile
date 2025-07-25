# Stage 1: Build Environment - Compiles the Rust module
FROM python:3.11-slim-bookworm AS builder

# Set environment variables for non-interactive installs
ENV PYTHONDONTWRITEBYTECODE 1
ENV PYTHONUNBUFFERED 1
ENV DEBIAN_FRONTEND=noninteractive

# Install build dependencies in a single, robust RUN command
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    curl \
    build-essential \
    pkg-config \
    libssl-dev && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Install Rust toolchain
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
FROM python:3.11-slim-bookworm

# Set environment variables
ENV PYTHONDONTWRITEBYTECODE 1
ENV PYTHONUNBUFFERED 1
ENV DEBIAN_FRONTEND=noninteractive

# Define kubectl version for deterministic builds
ARG KUBECTL_VERSION=1.28.4

# Install runtime dependencies (kubectl) and clean up in one go
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl && \
    # Install pinned kubectl version
    curl -LO "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl" && \
    install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl && \
    rm kubectl && \
    # Clean up apt cache and remove curl to keep the image small
    apt-get purge -y --auto-remove curl && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Copy installed Python packages and the built Rust wheel from the builder stage
COPY --from=builder /usr/local/lib/python3.11/site-packages/ /usr/local/lib/python3.11/site-packages/
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