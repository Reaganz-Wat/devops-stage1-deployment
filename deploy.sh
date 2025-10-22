#!/bin/bash

################################################################################
# DevOps Intern Stage 1 - Automated Deployment Script
# Author: Cool Keeds DevOps Team
# Description: Production-grade deployment automation script
################################################################################

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Log file setup
LOG_FILE="deploy_$(date +%Y%m%d_%H%M%S).log"
CLEANUP_MODE=false

################################################################################
# Utility Functions
################################################################################

log() {
    local level=$1
    shift
    local message="$@"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${timestamp} [${level}] ${message}" | tee -a "$LOG_FILE"
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $@" | tee -a "$LOG_FILE"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $@" | tee -a "$LOG_FILE"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $@" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $@" | tee -a "$LOG_FILE"
}

error_exit() {
    log_error "$1"
    exit "${2:-1}"
}

# Trap for unexpected errors
trap 'error_exit "Script failed at line $LINENO with command: $BASH_COMMAND" 99' ERR

################################################################################
# Stage 1: Collect and Validate User Input
################################################################################

collect_parameters() {
    log_info "=== Stage 1: Collecting Deployment Parameters ==="
    
    # Git Repository URL
    read -p "Enter Git Repository URL: " GIT_REPO_URL
    if [[ ! "$GIT_REPO_URL" =~ ^https://github\.com/.+/.+\.git$ ]] && [[ ! "$GIT_REPO_URL" =~ ^https://github\.com/.+/.+$ ]]; then
        error_exit "Invalid Git repository URL format" 10
    fi
    
    # Personal Access Token
    read -sp "Enter Personal Access Token (PAT): " PAT
    echo
    if [[ -z "$PAT" ]]; then
        error_exit "PAT cannot be empty" 11
    fi
    
    # Branch name
    read -p "Enter branch name (default: main): " BRANCH_NAME
    BRANCH_NAME=${BRANCH_NAME:-main}
    
    # SSH Details
    read -p "Enter remote server username: " SSH_USER
    if [[ -z "$SSH_USER" ]]; then
        error_exit "SSH username cannot be empty" 12
    fi
    
    read -p "Enter remote server IP address: " SERVER_IP
    if [[ ! "$SERVER_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        error_exit "Invalid IP address format" 13
    fi
    
    read -p "Enter SSH key path (default: ~/.ssh/id_rsa): " SSH_KEY_PATH
    SSH_KEY_PATH=${SSH_KEY_PATH:-~/.ssh/id_rsa}
    SSH_KEY_PATH="${SSH_KEY_PATH/#\~/$HOME}"
    
    if [[ ! -f "$SSH_KEY_PATH" ]]; then
        error_exit "SSH key file not found at: $SSH_KEY_PATH" 14
    fi
    
    # Application port
    read -p "Enter application internal port (e.g., 3000): " APP_PORT
    if [[ ! "$APP_PORT" =~ ^[0-9]+$ ]] || [[ "$APP_PORT" -lt 1 ]] || [[ "$APP_PORT" -gt 65535 ]]; then
        error_exit "Invalid port number. Must be between 1 and 65535" 15
    fi
    
    log_success "All parameters collected and validated successfully"
}

################################################################################
# Stage 2: Clone Repository
################################################################################

clone_repository() {
    log_info "=== Stage 2: Cloning Repository ==="
    
    # Extract repo name from URL
    REPO_NAME=$(basename "$GIT_REPO_URL" .git)
    PROJECT_DIR="$HOME/$REPO_NAME"
    
    # Add PAT to URL for authentication
    AUTH_URL=$(echo "$GIT_REPO_URL" | sed "s|https://|https://${PAT}@|")
    
    if [[ -d "$PROJECT_DIR" ]]; then
        log_warning "Repository already exists. Pulling latest changes..."
        cd "$PROJECT_DIR" || error_exit "Failed to navigate to $PROJECT_DIR" 20
        git fetch origin || error_exit "Failed to fetch from origin" 21
        git checkout "$BRANCH_NAME" || error_exit "Failed to checkout branch $BRANCH_NAME" 22
        git pull origin "$BRANCH_NAME" || error_exit "Failed to pull latest changes" 23
    else
        log_info "Cloning repository..."
        git clone -b "$BRANCH_NAME" "$AUTH_URL" "$PROJECT_DIR" || error_exit "Failed to clone repository" 24
        cd "$PROJECT_DIR" || error_exit "Failed to navigate to $PROJECT_DIR" 25
    fi
    
    log_success "Repository cloned/updated successfully"
}

################################################################################
# Stage 3: Verify Project Structure
################################################################################

verify_project_structure() {
    log_info "=== Stage 3: Verifying Project Structure ==="
    
    if [[ ! -f "Dockerfile" ]] && [[ ! -f "docker-compose.yml" ]] && [[ ! -f "docker-compose.yaml" ]]; then
        error_exit "No Dockerfile or docker-compose.yml found in repository" 30
    fi
    
    if [[ -f "docker-compose.yml" ]] || [[ -f "docker-compose.yaml" ]]; then
        USE_COMPOSE=true
        log_info "Found docker-compose.yml - will use Docker Compose"
    else
        USE_COMPOSE=false
        log_info "Found Dockerfile - will use Docker build"
    fi
    
    log_success "Project structure verified successfully"
}

################################################################################
# Stage 4: Test SSH Connection
################################################################################

test_ssh_connection() {
    log_info "=== Stage 4: Testing SSH Connection ==="
    
    ssh -i "$SSH_KEY_PATH" -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" "echo 'SSH connection successful'" || \
        error_exit "Failed to establish SSH connection to $SERVER_IP" 40
    
    log_success "SSH connection verified successfully"
}

################################################################################
# Stage 5: Prepare Remote Environment
################################################################################

prepare_remote_environment() {
    log_info "=== Stage 5: Preparing Remote Environment ==="
    
    ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" bash <<'ENDSSH'
        set -e
        
        echo "Updating system packages..."
        sudo apt-get update -y
        
        echo "Installing prerequisites..."
        sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common gnupg lsb-release
        
        # Install Docker if not present
        if ! command -v docker &> /dev/null; then
            echo "Installing Docker..."
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
            sudo apt-get update -y
            sudo apt-get install -y docker-ce docker-ce-cli containerd.io
        else
            echo "Docker already installed"
        fi
        
        # Install Docker Compose if not present
        if ! command -v docker-compose &> /dev/null; then
            echo "Installing Docker Compose..."
            sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
            sudo chmod +x /usr/local/bin/docker-compose
        else
            echo "Docker Compose already installed"
        fi
        
        # Install Nginx if not present
        if ! command -v nginx &> /dev/null; then
            echo "Installing Nginx..."
            sudo apt-get install -y nginx
        else
            echo "Nginx already installed"
        fi
        
        # Add user to docker group
        sudo usermod -aG docker $USER || true
        
        # Start and enable services
        sudo systemctl enable docker
        sudo systemctl start docker
        sudo systemctl enable nginx
        sudo systemctl start nginx
        
        # Verify installations
        echo "=== Installation Verification ==="
        docker --version
        docker-compose --version
        nginx -v
        
        echo "Remote environment prepared successfully"
ENDSSH
    
    log_success "Remote environment prepared successfully"
}

################################################################################
# Stage 6: Deploy Dockerized Application
################################################################################

deploy_application() {
    log_info "=== Stage 6: Deploying Dockerized Application ==="
    
    # Transfer project files to remote server
    log_info "Transferring project files..."
    REMOTE_PROJECT_DIR="/home/$SSH_USER/$REPO_NAME"
    
    ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" "mkdir -p $REMOTE_PROJECT_DIR"
    
    rsync -avz -e "ssh -i $SSH_KEY_PATH -o StrictHostKeyChecking=no" \
        --exclude='.git' \
        --exclude='node_modules' \
        --exclude='*.log' \
        "$PROJECT_DIR/" "$SSH_USER@$SERVER_IP:$REMOTE_PROJECT_DIR/" || \
        error_exit "Failed to transfer project files" 60
    
    log_success "Project files transferred successfully"
    
    # Deploy on remote server
    log_info "Building and running containers..."
    
    if [[ "$USE_COMPOSE" == true ]]; then
        ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" bash <<ENDSSH
            set -e
            cd $REMOTE_PROJECT_DIR
            
            # Stop and remove old containers
            docker-compose down || true
            
            # Build and start new containers
            docker-compose up -d --build
            
            # Wait for containers to be healthy
            sleep 10
            
            # Show container status
            docker-compose ps
            
            echo "Application deployed with Docker Compose"
ENDSSH
    else
        ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" bash <<ENDSSH
            set -e
            cd $REMOTE_PROJECT_DIR
            
            # Stop and remove old container
            docker stop $REPO_NAME || true
            docker rm $REPO_NAME || true
            
            # Build new image
            docker build -t $REPO_NAME:latest .
            
            # Run new container
            docker run -d \
                --name $REPO_NAME \
                -p $APP_PORT:$APP_PORT \
                --restart unless-stopped \
                $REPO_NAME:latest
            
            # Wait for container to start
            sleep 5
            
            # Show container status
            docker ps -f name=$REPO_NAME
            
            echo "Application deployed with Docker"
ENDSSH
    fi
    
    log_success "Application deployed successfully"
}

################################################################################
# Stage 7: Configure Nginx Reverse Proxy
################################################################################

configure_nginx() {
    log_info "=== Stage 7: Configuring Nginx Reverse Proxy ==="
    
    ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" bash <<ENDSSH
        set -e
        
        # Create Nginx configuration
        NGINX_CONF="/etc/nginx/sites-available/$REPO_NAME"
        
        sudo tee \$NGINX_CONF > /dev/null <<'EOF'
server {
    listen 80;
    server_name _;
    
    location / {
        proxy_pass http://localhost:$APP_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
    }
}
EOF
        
        # Enable site
        sudo ln -sf \$NGINX_CONF /etc/nginx/sites-enabled/$REPO_NAME
        
        # Remove default site if exists
        sudo rm -f /etc/nginx/sites-enabled/default
        
        # Test Nginx configuration
        sudo nginx -t
        
        # Reload Nginx
        sudo systemctl reload nginx
        
        echo "Nginx configured successfully"
ENDSSH
    
    log_success "Nginx reverse proxy configured successfully"
}

################################################################################
# Stage 8: Validate Deployment
################################################################################

validate_deployment() {
    log_info "=== Stage 8: Validating Deployment ==="
    
    # Check Docker service
    ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" "sudo systemctl is-active docker" || \
        error_exit "Docker service is not running" 80
    log_success "Docker service is running"
    
    # Check container status
    if [[ "$USE_COMPOSE" == true ]]; then
        ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" "cd $REMOTE_PROJECT_DIR && docker-compose ps | grep -q Up" || \
            error_exit "Containers are not running" 81
    else
        ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" "docker ps | grep -q $REPO_NAME" || \
            error_exit "Container is not running" 82
    fi
    log_success "Application containers are running"
    
    # Check Nginx service
    ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" "sudo systemctl is-active nginx" || \
        error_exit "Nginx service is not running" 83
    log_success "Nginx service is running"
    
    # Test endpoint locally on server
    log_info "Testing endpoint on remote server..."
    ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" "curl -f -s http://localhost:80 > /dev/null" || \
        log_warning "Local endpoint test failed - application might still be starting"
    
    # Test endpoint externally
    log_info "Testing endpoint from deployment machine..."
    sleep 5
    if curl -f -s "http://$SERVER_IP" > /dev/null; then
        log_success "Application is accessible at http://$SERVER_IP"
    else
        log_warning "External endpoint test failed - check firewall rules"
    fi
    
    log_success "Deployment validation completed"
}

################################################################################
# Cleanup Function
################################################################################

cleanup_deployment() {
    log_info "=== Cleaning up deployment ==="
    
    ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" bash <<ENDSSH
        set -e
        
        cd /home/$SSH_USER/$REPO_NAME || exit 0
        
        # Stop and remove containers
        if [[ -f "docker-compose.yml" ]] || [[ -f "docker-compose.yaml" ]]; then
            docker-compose down -v
        else
            docker stop $REPO_NAME || true
            docker rm $REPO_NAME || true
        fi
        
        # Remove images
        docker rmi $REPO_NAME:latest || true
        
        # Remove Nginx config
        sudo rm -f /etc/nginx/sites-enabled/$REPO_NAME
        sudo rm -f /etc/nginx/sites-available/$REPO_NAME
        sudo systemctl reload nginx
        
        # Remove project directory
        cd ~
        rm -rf /home/$SSH_USER/$REPO_NAME
        
        echo "Cleanup completed"
ENDSSH
    
    log_success "Cleanup completed successfully"
}

################################################################################
# Main Execution
################################################################################

main() {
    log_info "=================================================="
    log_info "DevOps Automated Deployment Script Started"
    log_info "Timestamp: $(date)"
    log_info "=================================================="
    
    # Check for cleanup flag
    if [[ "$#" -gt 0 ]] && [[ "$1" == "--cleanup" ]]; then
        CLEANUP_MODE=true
        log_info "Running in CLEANUP mode"
    fi
    
    if [[ "$CLEANUP_MODE" == true ]]; then
        # Collect only necessary parameters for cleanup
        read -p "Enter remote server username: " SSH_USER
        read -p "Enter remote server IP address: " SERVER_IP
        read -p "Enter SSH key path (default: ~/.ssh/id_rsa): " SSH_KEY_PATH
        SSH_KEY_PATH=${SSH_KEY_PATH:-~/.ssh/id_rsa}
        SSH_KEY_PATH="${SSH_KEY_PATH/#\~/$HOME}"
        read -p "Enter repository name to cleanup: " REPO_NAME
        
        cleanup_deployment
        log_success "Script completed successfully in CLEANUP mode"
        exit 0
    fi
    
    # Normal deployment flow
    collect_parameters
    clone_repository
    verify_project_structure
    test_ssh_connection
    prepare_remote_environment
    deploy_application
    configure_nginx
    validate_deployment
    
    log_info "=================================================="
    log_success "DEPLOYMENT COMPLETED SUCCESSFULLY!"
    log_info "Application URL: http://$SERVER_IP"
    log_info "Log file: $LOG_FILE"
    log_info "=================================================="
    
    exit 0
}

# Run main function
main "$@"