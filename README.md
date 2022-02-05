# Desktop KVM

## Current versions

- RHEL: 9.0 beta 0

## Steps

### 1. Install RHEL in minimal mode
**Reference:** ([Red Hat](https://developers.redhat.com/products/rhel/download))

- [Download ISO](https://developers.redhat.com/products/rhel/download)
- `sudo dd if=rhel-baseos-9.0-beta-0-x86_64-boot.iso of=/dev/sdc`

### 2. Install dependencies

- Install the KVM modules and libvirt
- Install Terraform ([HashiCorp](https://learn.hashicorp.com/tutorials/terraform/install-cli))

### 3. Install Windows

- TODO

### 4. Install macOS
**Reference:** ([GitHub](https://github.com/kholia/OSX-KVM))

- TODO

### 4. Install Linux

- TODO

## Other resources

- macOS & Windows KVM: [YouTube](https://www.youtube.com/watch?v=_JTEsQufSx4)

## Things to explore

- Generating the RHEL ISO with [Image Builder's CLI](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9-beta/html/composing_a_customized_rhel_system_image/creating-system-images-with-composer-command-line-interface_composing-a-customized-rhel-system-image) 
