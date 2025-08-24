# drpi-images
- repo for various images & scripts for my pi5

## Repo
```
drpi-images/
├── .github/workflows
├── alpine/
├── arch/
└── configs/
```


- **TFTP Server (localhost)**:
  - bootcode.bin - Pi bootloader
  - start4.elf - GPU firmware
  - fixup4.dat - Memory config
  - kernel8.img - Linux kernel
  - initramfs8 - pi customOS installer

- **Git Repository (git.drewpy.pro/drewpypro/drpi-images):**
  - alpine/alpine-rpi-latest.tar.gz - Base Alpine image
  - configs/packages.txt - Packages to install
  - configs/docker-compose.yml - Services to run
  - configs/setup.sh - Post-install scripts
