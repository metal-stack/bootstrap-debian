d-i partman-auto/method string raid
d-i partman-auto/choose_recipe select multiraid

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
@SWAP_RECIPE@
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
