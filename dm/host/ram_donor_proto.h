// MIT nxnative-mkw donor wire protocol with guest-range lifecycle operations.
#pragma once
#define DM_DONOR_CHUNK (256ull << 20)
#define DM_DONOR_OP "op"
#define DM_DONOR_SIZE "size"
#define DM_DONOR_SHMEM "shmem"
#define DM_DONOR_ERROR "error"
#define DM_DONOR_AVAILABLE "available"
#define DM_DONOR_OP_CREATE "create"
#define DM_DONOR_OP_AVAILABLE "available"
#define DM_DONOR_OP_RELEASE "release"
#define DM_DONOR_OP_FOOTPRINT "phys_footprint"
