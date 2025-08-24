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
COPY boot-server.sh /scripts/boot-server.sh
COPY download-boot-files.sh /scripts/download-boot-files.sh  
COPY build-initramfs.sh /scripts/build-initramfs.sh

# Make scripts executable
RUN chmod +x /scripts/*.sh

# Configure TFTP
RUN echo 'TFTP_DIRECTORY="/tftpboot"' > /etc/conf.d/in.tftpd && \
    echo 'TFTP_OPTIONS="--secure --create --verbose"' >> /etc/conf.d/in.tftpd

# Expose TFTP port
EXPOSE 69/udp

# Set working directory
WORKDIR /tftpboot

# Run the main boot script
CMD ["/scripts/boot-server.sh"]