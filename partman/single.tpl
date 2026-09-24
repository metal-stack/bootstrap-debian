d-i partman-auto/method string lvm
d-i partman-auto/choose_recipe select singledisk

d-i partman-auto/expert_recipe string         \
 singledisk ::                                \
   1 1 1 free                                 \
     $bios_boot{ }                            \
     method{ biosgrub }                       \
   .                                          \
   512 512 512 fat32                          \
     $primary{ }                              \
     $iflabel{ gpt }                          \
     method{ efi } format{ }                  \
   .                                          \
   1024 1024 1024 ext4                        \
     $primary{ }                              \
     $bootable{ }                             \
     method{ format } format{ }               \
     use_filesystem{ } filesystem{ ext4 }     \
     mountpoint{ /boot }                      \
   .                                          \
   10240 102400000 1000000000 ext3            \
     $primary{ }                              \
     method{ lvm }                            \
   .                                          \
   30720 30720 30720 ext4                     \
     $lvmok{ }                                \
     lv_name{ lv_root }                       \
     method{ format } format{ }               \
     use_filesystem{ } filesystem{ ext4 }     \
     mountpoint{ / }                          \
   .                                          \
@SWAP_RECIPE@
   @LV_VAR_MIN@ @LV_VAR_MAX@ @LV_VAR_MAX@ ext4 \
     $lvmok{ }                                \
     lv_name{ lv_var }                        \
     method{ format } format{ }               \
     use_filesystem{ } filesystem{ ext4 }     \
     mountpoint{ /var }                       \
   .
