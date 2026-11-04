// Only the lifetime-lock and unmanaged legacy-client scenarios need a driver;
// ordinary management tests call the production terminal tool.
#include "../save_manager.h"
#include "../save_sync.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
int main(int argc, char **argv) {
    if (argc != 4) return 2;
    if (!strcmp(argv[1],"legacy")) {
        save_sync_mount(argv[2],argv[3]);
        return save_sync_flush(20000) ? 0 : 1;
    }
    if (!strcmp(argv[1],"prepare") || !strcmp(argv[1],"hold")) {
        char path[4096], error[1024]; int fd;
        if (dm_saves_prepare(argv[2],argv[3],path,sizeof path,&fd,error,sizeof error)) {
            fprintf(stderr,"%s\n",error); return 1;
        }
        puts(path); fflush(stdout);
        if (!strcmp(argv[1],"hold")) { char c; (void)read(STDIN_FILENO,&c,1); }
        close(fd); return 0;
    }
    return 2;
}
