#include "../picture_lut.h"
#include <assert.h>

static const char identity[]="TITLE \"Identity\"\nLUT_3D_SIZE 2\n"
    "0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n";
static void rejects(const char *text) {
    dm_cube cube; assert(dm_cube_parse(text,strlen(text),&cube)!=DM_CUBE_OK && !cube.rgba);
}
int main(int argc,char **argv) {
    dm_cube cube;
    assert(dm_cube_parse(identity,strlen(identity),&cube)==DM_CUBE_OK);
    assert(cube.size==2 && cube.rgba[4]==1 && cube.rgba[5]==0 && cube.rgba[16]==0 && cube.rgba[18]==1);
    assert(cube.min[0]==0 && cube.max[2]==1 && cube.rgba[31]==1); free(cube.rgba);
    char text[2048];
    snprintf(text,sizeof text,"\xef\xbb\xbf# comment\r\nDOMAIN_MIN -1 -2 -3\r\nDOMAIN_MAX 1 2 3\r\n%s",identity);
    assert(dm_cube_parse(text,strlen(text),&cube)==DM_CUBE_OK && cube.min[1]==-2 && cube.max[2]==3); free(cube.rgba);
    snprintf(text,sizeof text,"LUT_3D_INPUT_RANGE -1 2\n%s",identity);
    assert(dm_cube_parse(text,strlen(text),&cube)==DM_CUBE_OK && cube.min[0]==-1 && cube.max[2]==2); free(cube.rgba);
    rejects(""); rejects("LUT_3D_SIZE 1\n"); rejects("LUT_3D_SIZE 66\n"); rejects("LUT_3D_SIZE 2.5\n");
    rejects("LUT_1D_SIZE 2\n0 0 0\n1 1 1\n"); rejects("LUT_3D_SIZE 2\n0 0 0\n");
    snprintf(text,sizeof text,"%s0 0 0\n",identity); rejects(text);
    snprintf(text,sizeof text,"LUT_3D_SIZE 2\n%s",identity); rejects(text);
    snprintf(text,sizeof text,"DOMAIN_MIN 1 1 1\nDOMAIN_MAX 0 0 0\n%s",identity); rejects(text);
    snprintf(text,sizeof text,"DOMAIN_MAX inf 1 1\n%s",identity); rejects(text);
    const char *remaining=strstr(identity,"1 0 0\n");
    for (const char **p=(const char *[]){"nan 0 0","inf 0 0","999999 0 0","0 0","0 0 0 0","0x1p0 0 0","0.10.20.3","1-1-1",NULL};*p;p++) {
        snprintf(text,sizeof text,"LUT_3D_SIZE 2\n%s\n%s",*p,remaining); rejects(text);
    }
    assert(dm_cube_parse("x",DM_CUBE_MAX_BYTES+1,&cube)==DM_CUBE_TOO_LARGE);
    assert(dm_cube_read_file("/missing/nxnative-lut.cube",&cube)==DM_CUBE_IO && !cube.rgba);
    if (argc>1) {
        assert(dm_cube_read_file(argv[1],&cube)==DM_CUBE_OK && cube.size==33);
        for (int c=0;c<3;c++) assert(cube.rgba[c]==0 && cube.rgba[(33*33*33-1)*4+c]==1);
        free(cube.rgba);
    }
    puts("PASS: bounded CUBE parsing, axis order, domains, endpoints and invalid files");
}
