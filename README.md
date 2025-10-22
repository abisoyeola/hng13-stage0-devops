# Automated Deployment Script (DevOps Intern Stage 1)

## Overview
`deploy.sh` automates setup, deployment, and configuration of a Dockerized app on a remote Linux server (EC2). It installs Docker, Docker Compose, and Nginx, transfers the project, runs containers, and configures Nginx as a reverse proxy.

## Usage
Make executable:
```sh
chmod +x deploy.sh
