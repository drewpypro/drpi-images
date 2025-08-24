# Dockerfile for Pi Network Boot Server
FROM alpine:latest

# Install required packages
RUN apk add --no-cache \
    tftp-hpa \
    wget \
    cpio \
    gzip \
    findutils \
    curl \
    bash \
    git

# Create directories
RUN mkdir -p /tftpboot /scripts /logs

# Create the main boot script
COPY scripts/boot-server.sh /scripts/boot-server.sh
COPY scripts/download-boot-files.sh /scripts/download-boot-files.sh  
COPY scripts/build-initramfs.sh /scripts/build-initramfs.sh

# Make scripts executable
RUN chmod +x scripts/*.sh

# Expose TFTP port
EXPOSE 69/udp

# Run the main boot script
CMD ["scripts/boot-server.sh"]