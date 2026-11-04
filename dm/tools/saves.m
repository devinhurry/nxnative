// Native command driver; scripts/saves.py builds this with the shared backend.
#include "../host/save_manager.h"
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
    if (argc < 4 || argc > 6) { fputs("usage: saves ROOT TITLE COMMAND [ARG1 [ARG2]]\n",stderr); return 2; }
    char error[1024];
    char *json = dm_saves_command(argv[1],argv[2],argv[3],argc > 4 ? argv[4] : NULL,argc > 5 ? argv[5] : NULL,error,sizeof error);
    if (!json) { fprintf(stderr,"[RED] saves: %s\n",error); return 1; }
    puts(json); free(json); return 0;
}
