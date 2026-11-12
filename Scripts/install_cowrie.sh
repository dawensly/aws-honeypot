#!/bin/bash
mkdir ~/honeypot && cd ~/honeypot

# Create the environment
python3 -m venv cowrie-env

# Activate the environment
source cowrie-env/bin/activate

# Upgrade pip and install Cowrie
python -m pip install --upgrade pip
pip install cowrie

# Initialize the Honeypot
cowrie init

# Optional: configure cowrie.cfg here using 'sed' or 'echo' instead of an interactive editor
# cp etc/cowrie.cfg.dist etc/cowrie.cfg

cowrie start # manual start, for first testing only