### Unattended Installation
d-i auto-install/enable boolean true
d-i debconf/priority select critical

### Localization
d-i debian-installer/locale string @LOCALE@
d-i localechooser/supported-locales multiselect @LOCALE@
d-i console-setup/ask_detect boolean false
d-i keyboard-configuration/xkb-keymap select @KEYMAP@

### Network configuration
d-i netcfg/choose_interface select auto
d-i netcfg/hostname string @HOSTNAME@
d-i netcfg/get_hostname string @HOSTNAME@
d-i netcfg/get_domain string @DOMAIN@
d-i hw-detect/load_firmware boolean true
@OFFLINE_ONLY@d-i netcfg/dhcp_failed note
@OFFLINE_ONLY@d-i netcfg/dhcp_options select Do not configure the network at this time
@OFFLINE_ONLY@d-i netcfg/get_nameservers string
@OFFLINE_ONLY@d-i netcfg/no_default_route boolean true
@OFFLINE_ONLY@d-i netcfg/confirm_static boolean true

### Mirror settings
d-i mirror/country string manual
d-i mirror/http/hostname string deb.debian.org
d-i mirror/http/directory string /debian
d-i mirror/http/proxy string
d-i mirror/suite string @SUITE@
d-i mirror/codename string @SUITE@

### Account setup
d-i passwd/root-login boolean false

d-i passwd/make-user boolean true
d-i passwd/user-fullname string @USER_FULLNAME@
d-i passwd/username string @USERNAME@
d-i passwd/user-password-crypted password @USERHASH@
d-i passwd/user-uid string 1000

### Clock and time zone setup
d-i clock-setup/utc boolean true
d-i time/zone string @TIMEZONE@
d-i clock-setup/ntp boolean true

### Partitioning
d-i partman-auto/method string raid
d-i partman-partitioning/default_label string gpt
d-i partman-lvm/device_remove_lvm boolean true
d-i partman-lvm/confirm boolean true
d-i partman-lvm/confirm_nooverwrite boolean true
d-i partman-md/device_remove_md boolean true
d-i partman-md/confirm boolean true
d-i partman-md/confirm_nooverwrite boolean true
d-i partman-partitioning/confirm_write_new_label boolean true
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true
d-i partman-basicmethods/method_only boolean false
d-i partman-auto/choose_recipe select multiraid
d-i partman-auto-lvm/new_vg_name string vg0
d-i partman-auto-lvm/guided_size string 99%
d-i partman-auto/cap-ram string 4096

### Partman recipe
d-i partman-auto/expert_recipe string         \
 multiraid ::                                 \
   1 1 1 free                                 \
     $lvmignore{ }                            \
     $bios_boot{ }                            \
     method{ biosgrub }                       \
   .                                          \
   512 512 512 fat32                          \
     $lvmignore{ }                            \
     $primary{ }                              \
     $iflabel{ gpt }                          \
     method{ efi } format{ }                  \
   .                                          \
   1024 1024 1024 raid                        \
     $lvmignore{ }                            \
     $primary{ }                              \
     $bootable{ }                             \
     method{ raid }                           \
   .                                          \
   10240 102400000 1000000000 raid            \
     $lvmignore{ }                            \
     $primary{ }                              \
     method{ raid }                           \
   .                                          \
   2048 102400000 200% raid                   \
     $lvmignore{ }                            \
     $primary{ }                              \
     method{ raid }                           \
   .                                          \
   30720 30720 30720 ext4                     \
     $defaultignore{ }                        \
     $lvmok{ }                                \
     lv_name{ lv_root }                       \
     method{ format } format{ }               \
     use_filesystem{ } filesystem{ ext4 }     \
     mountpoint{ / }                          \
   .                                          \
   @LV_VAR_MIN@ @LV_VAR_MAX@ @LV_VAR_MAX@ ext4 \
     $defaultignore{ }                        \
     $lvmok{ }                                \
     lv_name{ lv_var }                        \
     method{ format } format{ }               \
     use_filesystem{ } filesystem{ ext4 }     \
     mountpoint{ /var }                       \
   .

### Base system installation
d-i base-installer/install-recommends boolean true
d-i base-installer/kernel/image string linux-image-amd64

### Apt setup
d-i apt-setup/non-free-firmware boolean true
d-i apt-setup/non-free boolean false
d-i apt-setup/contrib boolean false
d-i apt-setup/services-select multiselect @APT_SERVICES@
d-i apt-setup/security_host string security.debian.org
d-i apt-setup/cdrom/set-first boolean false
@OFFLINE_ONLY@d-i apt-setup/use_mirror boolean false

### Package selection
tasksel tasksel/first multiselect none
d-i pkgsel/include string openssh-server python3 mdadm
d-i pkgsel/upgrade select @PKGSEL_UPGRADE@
d-i pkgsel/update-policy select @UPDATE_POLICY@

### Disk detection
d-i partman/early_command string sh /cdrom/custom/raid-setup.sh

### RAID
# without this a failed disk drops every later boot into an initramfs prompt
d-i mdadm/boot_degraded boolean true

### Boot loader installation
d-i grub-installer/only_debian boolean true
d-i grub-installer/with_other_os boolean true
d-i grub-installer/force-efi-extra-removable boolean true
d-i grub-installer/bootdev string default

### Finishing up the installation
d-i preseed/late_command string \
 cp -r /cdrom/custom /target/custom; \
 sh /cdrom/custom/sync-esp.sh; @LATE_OFFLINE@\
 in-target sh -c 'usermod -p "!" root'; \
 in-target sh -c 'mkdir -p --mode=0700 /home/@USERNAME@/.ssh && cat /custom/authorized_keys > /home/@USERNAME@/.ssh/authorized_keys && chmod 0600 /home/@USERNAME@/.ssh/authorized_keys && chown -R 1000:1000 /home/@USERNAME@/.ssh'; \
 in-target sh -c 'sed -i "s/^#\?PermitRootLogin.*$/PermitRootLogin no/g" /etc/ssh/sshd_config'; \
 in-target sh -c 'sed -i "s/^#\?PasswordAuthentication.*$/PasswordAuthentication no/g" /etc/ssh/sshd_config'; \
 in-target sh -c 'rm -f /etc/ssh/ssh_host_*_key* && mkdir -p /usr/lib/systemd/system && cp /custom/ssh-host-keygen.service /usr/lib/systemd/system/ssh-host-keygen.service && systemctl enable ssh-host-keygen.service'; \
 in-target sh -c 'echo "IPv4: \\\4" >> /etc/issue && echo "IPv6: \\\6" >> /etc/issue && echo "" >> /etc/issue'; \
 in-target sh -c 'echo "@USERNAME@ ALL=(ALL:ALL) NOPASSWD: ALL" >> /etc/sudoers'; \
 in-target sh -c 'eject || true'; \
 chown -R 1000:1000 /target/home/@USERNAME@; \
 rm -r /target/custom;
d-i debian-installer/splash boolean false

### Shutdown machine
d-i finish-install/reboot_in_progress note
d-i debian-installer/exit/poweroff boolean true
