// Strict, bounded reader for display-referred 3D .cube colour tables.
// Shared by the native file picker and renderer, including standalone launchers.
#pragma once
#include <ctype.h>
#include <locale.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef __APPLE__
#include <xlocale.h>
#endif

enum { DM_CUBE_MAX_BYTES = 32 * 1024 * 1024 };
enum { DM_CUBE_OK, DM_CUBE_IO, DM_CUBE_TOO_LARGE, DM_CUBE_FORMAT, DM_CUBE_DIMENSION, DM_CUBE_VALUES, DM_CUBE_MEMORY };
typedef struct { unsigned size; float min[3], max[3]; float *rgba; } dm_cube;

static inline int dm_cube_numbers(char *p, float *out, unsigned count, locale_t loc) {
    for (unsigned i=0;i<count;i++) {
        while (isspace((unsigned char)*p)) p++;
        char *end; out[i]=strtof_l(p,&end,loc);
        if (end==p || !isfinite(out[i]) || (*end && !isspace((unsigned char)*end))) return 0;
        for (char *q=p;q<end;q++) if (*q=='x' || *q=='X') return 0;
        p=end;
    }
    while (isspace((unsigned char)*p)) p++;
    return !*p;
}

static inline int dm_cube_parse(const char *source, size_t length, dm_cube *out) {
    *out=(dm_cube){0};
    if (length>DM_CUBE_MAX_BYTES) return DM_CUBE_TOO_LARGE;
    if (!source || !length || memchr(source,0,length)) return DM_CUBE_FORMAT;
    char *text=malloc(length+1);
    locale_t loc=newlocale(LC_NUMERIC_MASK,"C",NULL);
    if (!text || !loc) { free(text); if (loc) freelocale(loc); return DM_CUBE_MEMORY; }
    memcpy(text,source,length); text[length]=0;
    dm_cube cube={.max={1,1,1}};
    size_t entries=0; int error=DM_CUBE_FORMAT, have_size=0, have_min=0, have_max=0;
    char *next=text;
    if (length>=3 && !memcmp(next,"\xef\xbb\xbf",3)) next+=3;
    for (char *line;(line=strsep(&next,"\r\n"));) {
        char *comment=strchr(line,'#'); if (comment) *comment=0;
        while (isspace((unsigned char)*line)) line++;
        if (!*line) continue;
        if (!strncmp(line,"TITLE",5) && isspace((unsigned char)line[5])) continue;
        if (!strncmp(line,"LUT_3D_SIZE",11) && isspace((unsigned char)line[11])) {
            float size;
            if (have_size || entries || !dm_cube_numbers(line+11,&size,1,loc)) goto done;
            if (size<2 || size>65 || size!=floorf(size)) { error=DM_CUBE_DIMENSION; goto done; }
            cube.size=(unsigned)size; have_size=1;
            cube.rgba=malloc((size_t)cube.size*cube.size*cube.size*4*sizeof(float));
            if (!cube.rgba) { error=DM_CUBE_MEMORY; goto done; }
            continue;
        }
        if (!strncmp(line,"DOMAIN_MIN",10) && isspace((unsigned char)line[10])) {
            if (have_min || entries || !dm_cube_numbers(line+10,cube.min,3,loc)) goto done;
            have_min=1; continue;
        }
        if (!strncmp(line,"DOMAIN_MAX",10) && isspace((unsigned char)line[10])) {
            if (have_max || entries || !dm_cube_numbers(line+10,cube.max,3,loc)) goto done;
            have_max=1; continue;
        }
        if (!strncmp(line,"LUT_3D_INPUT_RANGE",18) && isspace((unsigned char)line[18])) {
            float range[2];
            if (have_min || have_max || entries || !dm_cube_numbers(line+18,range,2,loc)) goto done;
            for (int c=0;c<3;c++) { cube.min[c]=range[0]; cube.max[c]=range[1]; }
            have_min=have_max=1; continue;
        }
        if (!have_size || entries>=(size_t)cube.size*cube.size*cube.size) goto done;
        float *rgba=cube.rgba+4*entries;
        if (!dm_cube_numbers(line,rgba,3,loc)) { error=DM_CUBE_VALUES; goto done; }
        for (int c=0;c<3;c++) if (fabsf(rgba[c])>65504) { error=DM_CUBE_VALUES; goto done; }
        rgba[3]=1; entries++;
    }
    if (!have_size || entries!=(size_t)cube.size*cube.size*cube.size) goto done;
    for (int c=0;c<3;c++) {
        float span=cube.max[c]-cube.min[c];
        if (!(span>0) || !isfinite(span) || !isfinite(1.0f/span)) goto done;
    }
    *out=cube; cube.rgba=NULL; error=DM_CUBE_OK;
done:
    free(cube.rgba); free(text); freelocale(loc); return error;
}

static inline int dm_cube_read_file(const char *path, dm_cube *out) {
    *out=(dm_cube){0};
    FILE *file=path ? fopen(path,"rb") : NULL;
    if (!file) return DM_CUBE_IO;
    if (fseek(file,0,SEEK_END)) { fclose(file); return DM_CUBE_IO; }
    long length=ftell(file);
    if (length<0 || fseek(file,0,SEEK_SET)) { fclose(file); return DM_CUBE_IO; }
    if ((unsigned long)length>DM_CUBE_MAX_BYTES) { fclose(file); return DM_CUBE_TOO_LARGE; }
    char *text=malloc((size_t)length+1);
    if (!text) { fclose(file); return DM_CUBE_MEMORY; }
    int error=fread(text,1,(size_t)length,file)==(size_t)length ? dm_cube_parse(text,(size_t)length,out) : DM_CUBE_IO;
    free(text); fclose(file); return error;
}

static inline int dm_cube_validate_file(const char *path) {
    dm_cube cube; int error=dm_cube_read_file(path,&cube); free(cube.rgba); return error;
}
