FROM ubuntu:26.04

# Avoid interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install OpenSSH server and clean up
RUN apt-get update && \
    apt-get install -y \
    openssh-server \
    sudo \
    && apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Create SSH directory and configure SSH
RUN mkdir -p /var/run/sshd && \
    mkdir -p /root/.ssh && \
    chmod 700 /root/.ssh

# Configure SSH for password authentication
RUN sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config && \
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config && \
    sed -i 's/UsePAM yes/UsePAM no/' /etc/ssh/sshd_config

# Create a boundary user with sudo privileges
RUN useradd -m -s /bin/bash boundary && \
    echo "boundary:password" | chpasswd && \
    usermod -aG sudo boundary && \
    echo "boundary ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# Set root password
RUN echo "root:password" | chpasswd

# Expose SSH port
EXPOSE 22

# Start SSH daemon
CMD ["/usr/sbin/sshd", "-D"]