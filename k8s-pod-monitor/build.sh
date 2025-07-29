#!/bin/bash
set -e
echo "STEP 1: Setting up Python virtual environment..."
if [ ! -d "venv" ]; then
    echo "  - Creating virtual environment 'venv'..."
    python3 -m venv venv
else
    echo "  - Virtual environment 'venv' already exists."
fi

if [[ "$OSTYPE" == "linux-gnu"* || "$OSTYPE" == "darwin"* ]]; then
    source venv/bin/activate
elif [[ "$OSTYPE" == "cygwin" || "$OSTYPE" == "msys" || "$OSTYPE" == "win32" ]]; then
    source venv/Scripts/activate
else
    echo "WARNING: Unsupported OS for venv activation. Please activate manually."
fi
echo "  - Virtual environment activated."

echo "STEP 2: Installing Python dependencies from requirements.txt..."
pip install --upgrade pip
pip install -r requirements.txt
echo "  - Python dependencies installed successfully."

echo "STEP 3: Attempting to build optional Rust accelerator module..."
if command -v cargo &> /dev/null; then
    echo "  - Rust toolchain (cargo) found."
    echo "  - Building Rust module with maturin..."
    if maturin build --release --strip --manifest-path rust_analyzer/Cargo.toml; then
        echo "  - Rust module built successfully!"
        WHEEL_FILE=$(find rust_analyzer/target/wheels -name "*.whl" | head -n 1)
        if [ -f "$WHEEL_FILE" ]; then
            echo "  - Installing Rust module: $WHEEL_FILE"
            pip install "$WHEEL_FILE" --force-reinstall
            echo "  - Rust module installed into virtual environment."
        else
            echo "WARNING: Build succeeded but no wheel file found. Continuing in pure Python mode."
        fi
    else
        echo "===================================================================="
        echo "WARNING: Rust module build failed. This is not a critical error."
        echo "  - The application will run in PURE PYTHON mode."
        echo "===================================================================="
    fi
else
    echo "===================================================================="
    echo "WARNING: Rust toolchain (cargo) not found. Skipping Rust module build."
    echo "  - The application will run in PURE PYTHON mode."
    echo "===================================================================="
fi
echo "Build process complete."
