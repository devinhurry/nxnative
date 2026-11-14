# RAM donor implementation and licensing

The XPC endpoint and app-extension mechanism derives from the MIT-licensed
[nxnative-mkw implementation](https://github.com/Thijs2004/nxnative-mkw/tree/main/dm/ios).
The immutable reference blobs are `45d18cfcf27e5dfc15141658610eceac8294391c`
(`RamDonor/main.m`), `e391b75cdec82ee55a839a916038581975908508`
(`Sources/ram_donor.m`) and `08560b7a3891fb33fde1adca49cafc8412fc6c07`
(`Sources/ram_donor_proto.h`). The original MIT notice is retained in LICENSE.

The runtime uses up to four donors, 256 MiB chunks and headroom, and fixed shared
remapping of heap, stack and alias ranges. Donors start early and shut down after
mapping. The protocol supports page release, available-memory queries and
physical-footprint reporting.

The iOS packer embeds `DmRamDonor.appex`; the main process attaches its native
range/release hooks during initialization. `DM_RAM_DONOR=0` disables the donor.
Failure preserves the anonymous guest backing; an explicitly selected file heap
keeps its file backing. Released donated pages keep their shared VM object and
are zeroed before reopening. Diagnostic accounting identifies donor objects,
including their Metal aliases, separately from this process's charged total.

Host checks and iOS compilation do not establish that extension startup and
memory ownership work on a particular phone/system/signing combination. Device
validation must inspect the actual donor startup/mapping log and kernel footprint.
