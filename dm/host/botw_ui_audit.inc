// Opt-in, passive JSONL evidence. No guest writes and no input/visibility policy.
// Included after the native pointer/name validators in hle_botw_touch_menu.c.
static _Atomic(FILE *) g_ui_audit;
static pthread_mutex_t g_ui_audit_mu = PTHREAD_MUTEX_INITIALIZER;
static uint64_t g_ui_audit_seq, g_ui_audit_screen_hash[256];
static uint64_t g_ui_audit_state_hash, g_ui_audit_state_frame;
typedef struct {
    uintptr_t screen, root;
    uint64_t frame;
    int registered, input, mode;
    char name[64];
} ui_audit_owner;
static ui_audit_owner g_ui_audit_owners[256];
typedef struct { char *text; size_t capacity, used; int full; } ui_audit_json;

static void ui_audit_add(ui_audit_json *j, const char *format, ...) {
    if (j->full) return;
    va_list args; va_start(args, format);
    int n = vsnprintf(j->text + j->used, j->capacity - j->used, format, args);
    va_end(args);
    if (n < 0 || (size_t)n >= j->capacity - j->used) { j->full = 1; return; }
    j->used += (size_t)n;
}
static void ui_audit_string(ui_audit_json *j, const char *s) {
    ui_audit_add(j, "\"");
    for (; *s && !j->full; s++) {
        unsigned char c = (unsigned char)*s;
        if (c == '"' || c == '\\') ui_audit_add(j, "\\%c", c);
        else if (c < 0x20 || c >= 0x7f) ui_audit_add(j, "\\u%04x", c);
        else ui_audit_add(j, "%c", c);
    }
    ui_audit_add(j, "\"");
}
static uint64_t ui_audit_hash(const char *s) {
    uint64_t h = UINT64_C(14695981039346656037);
    for (; *s; s++) { h ^= (unsigned char)*s; h *= UINT64_C(1099511628211); }
    return h;
}
static const char g_ui_audit_policy[] =
#define BOTW_UI_SCREEN(match, pattern, role) #match ":" pattern ":" #role "\n"
#include "botw_touch_screens.inc"
#undef BOTW_UI_SCREEN
;
static void ui_audit_write(const char *event, uint64_t frame, const ui_audit_json *j) {
    if (j->full) { LOG("[RED] BOTW UI audit record exceeds its bound"); return; }
    fprintf(g_ui_audit, "{\"event\":\"%s\",\"seq\":%llu,\"frame\":%llu,%s}\n", event,
        (unsigned long long)++g_ui_audit_seq, (unsigned long long)frame, j->text);
    fflush(g_ui_audit);
}
static void ui_audit_open(const char *path) {
    if (!path || !*path || g_ui_audit) return;
    FILE *file = fopen(path, "a");
    if (!file) { LOG("[RED] Cannot open BOTW UI audit: %s", path); return; }
    // Publish only after the complete session header; callbacks can then append.
    fprintf(file, "{\"event\":\"session\",\"seq\":%llu,\"frame\":0,\"schema\":1,\"game\":\"%s\",\"build\":\"%s\",\"policy\":\"%016llx\"}\n",
        (unsigned long long)++g_ui_audit_seq, DM_GAME_ID, BOTW_BUILD,
        (unsigned long long)ui_audit_hash(g_ui_audit_policy));
    fflush(file); atomic_store_explicit(&g_ui_audit, file, memory_order_release);
}
static void ui_audit_path(uintptr_t pane, char out[512]) {
    char names[PANE_PATH_DEPTH][25]; unsigned n = 0;
    while (pane && n < PANE_PATH_DEPTH && selector_range(pane, PANE_NAME + 24)) {
        memcpy(names[n],(const void *)(pane+PANE_NAME),24); names[n++][24]=0;
        uintptr_t parent = selector_read_ptr(pane, PANE_PARENT);
        if (parent == pane) break;
        pane = parent;
    }
    size_t used = 0; out[0] = 0;
    while (n) {
        int count = snprintf(out + used, 512 - used, "%s%s", used ? "/" : "", names[--n]);
        if (count < 0 || (size_t)count >= 512 - used) break;
        used += (size_t)count;
    }
}
static void ui_audit_screen(uint32_t index, uintptr_t screen, uintptr_t root, const char *name, int registered,
                            int shown, int mode, int input, int visible, uint64_t frame) {
    if (!g_ui_audit || index >= 256) return;
    char text[1024]; ui_audit_json j = {text,sizeof text,0,0};
    ui_audit_add(&j, "\"index\":%u,\"screen\":", index); ui_audit_string(&j, name);
    ui_audit_add(&j, ",\"root\":\"0x%llx\"", (unsigned long long)root);
    ui_audit_add(&j, ",\"registered\":%d,\"shown\":%d,\"mode\":%d,\"input\":%d,\"visible\":%d",
        registered, shown, mode, input, visible);
    uint64_t hash = ui_audit_hash(j.text);
    pthread_mutex_lock(&g_ui_audit_mu);
    g_ui_audit_owners[index] = (ui_audit_owner){.screen=screen,.root=root,.frame=frame,
        .registered=registered,.input=input,.mode=mode};
    snprintf(g_ui_audit_owners[index].name,sizeof g_ui_audit_owners[index].name,"%s",name);
    if (g_ui_audit_screen_hash[index] != hash) {
        g_ui_audit_screen_hash[index] = hash; ui_audit_write("screen", frame, &j);
    }
    pthread_mutex_unlock(&g_ui_audit_mu);
}
static void ui_audit_target(ui_audit_json *j, int *count, const char *kind, int index,
                            uintptr_t pane, const float rect[4], uint64_t button,
                            int adjustment, int focus_only) {
    if (!isfinite(rect[0]) || !isfinite(rect[1]) || !isfinite(rect[2]) || !isfinite(rect[3]) ||
        rect[2] <= 0 || rect[3] <= 0) return;
    char path[512], id[560]; ui_audit_path(pane, path);
    if (path[0]) snprintf(id, sizeof id, "%s:%s:%d", kind, path, adjustment);
    else snprintf(id, sizeof id, "%s:native:%llu:%d", kind, (unsigned long long)button, index);
    ui_audit_add(j, "%s{\"id\":", (*count)++ ? "," : ""); ui_audit_string(j, id);
    ui_audit_add(j, ",\"kind\":"); ui_audit_string(j, kind);
    ui_audit_add(j, ",\"path\":"); ui_audit_string(j, path);
    ui_audit_add(j, ",\"rect\":[%.5f,%.5f,%.5f,%.5f],\"button\":%llu,\"adjustment\":%d,\"focus_only\":%d}",
        rect[0], rect[1], rect[2], rect[3], (unsigned long long)button, adjustment, focus_only);
}
static void ui_audit_view(const dm_botw_touch_menu_view *v, int active, uint64_t frame) {
    if (!g_ui_audit || !dm_botw_touch_hud_active()) return;
    uintptr_t manager = atomic_load_explicit(&g_validated_box_cursor_manager, memory_order_acquire);
    uintptr_t focus = selector_read_ptr(manager, 0x48);
    uintptr_t screen = v->generic_screen && (active || !focus) ? v->generic_screen : selector_read_ptr(focus, 0x20);
    // A view/focus pointer can outlive the screen during teardown. Never call
    // a guest virtual method through it for diagnostics. Only the registry's
    // already validated, current-frame names establish an audit owner.
    ui_audit_owner owner = {0};
    uintptr_t presented_root = atomic_load_explicit(&g_presented_menu_root,memory_order_acquire);
    pthread_mutex_lock(&g_ui_audit_mu);
    for (int i=0;i<256;i++) {
        const ui_audit_owner *candidate=&g_ui_audit_owners[i];
        if (!candidate->registered || frame<candidate->frame || frame-candidate->frame>2) continue;
        if (candidate->root==presented_root && presented_root) owner=*candidate;
    }
    for (int i=0;i<256;i++) {
        const ui_audit_owner *candidate=&g_ui_audit_owners[i];
        if (candidate->screen==screen && screen && candidate->registered && candidate->mode==2 &&
            frame>=candidate->frame && frame-candidate->frame<=2) { owner=*candidate; break; }
    }
    pthread_mutex_unlock(&g_ui_audit_mu);
    // A closing view must not donate its targets to a different presented owner.
    active = active && owner.screen == screen && owner.input && owner.mode == 2;
    char path[512] = {0};
    if (owner.screen && owner.input && owner.mode==2)
        ui_audit_path(selector_read_ptr(selector_read_ptr(focus, 0x18), 0x60), path);
    char text[131072]; ui_audit_json j = {text,sizeof text,0,0};
    ui_audit_add(&j, "\"screen\":"); ui_audit_string(&j, owner.name);
    ui_audit_add(&j, ",\"root\":\"0x%llx\"", (unsigned long long)owner.root);
    ui_audit_add(&j, ",\"focus\":"); ui_audit_string(&j, path);
    pthread_mutex_lock(&g_menu_mu);
    ui_audit_add(&j, ",\"menu_presented\":%d,\"gameplay\":%d", g_presented_menu, g_presented_gameplay);
    pthread_mutex_unlock(&g_menu_mu);
    ui_audit_add(&j, ",\"owner_input\":%d,\"owner_mode\":%d", owner.input, owner.mode);
    ui_audit_add(&j, ",\"hero_path\":%d", active && v->map_visible && v->hero_path);
    ui_audit_add(&j, ",\"active\":%d,\"group\":%d,\"mode\":\"%s\",\"targets\":[", active,
        v->generic_group, v->map_visible ? "map" : v->popup_visible ? "popup" :
        v->inventory_visible ? "inventory" : "generic");
    int count = 0;
    if (active) {
        if (v->map_visible) ui_audit_target(&j,&count,"map",0,v->map_pane,v->map,0,0,0);
        if (v->back_valid) ui_audit_target(&j,&count,"back",0,0,v->back,DM_BTN_B,0,0);
        for (int i=0;i<v->footer_action_count;i++)
            ui_audit_target(&j,&count,"hint",i,0,v->footer_actions[i],v->footer_action_buttons[i],0,0);
        for (int i=0;i<v->category_count && !v->popup_visible;i++)
            ui_audit_target(&j,&count,"category",v->category_ids[i],v->category_panes[i],v->categories[i],0,0,1);
        if (v->generic_mode) {
            for (int i=0;i<v->generic_count;i++) {
                const dm_botw_touch_menu_target *t=&v->generic_targets[i];
                ui_audit_target(&j,&count,"target",i,t->pane,t->rect,0,t->adjustment,t->focus_only);
            }
        } else if (v->popup_visible) {
            for (int i=0;i<v->popup_count;i++)
                ui_audit_target(&j,&count,"popup",i,v->popup_row_panes[i],v->popup_rows[i],DM_BTN_A,0,0);
        } else {
            for (int i=0;i<v->slot_count;i++)
                ui_audit_target(&j,&count,"slot",i,v->slot_panes[i],v->slots[i],DM_BTN_A,0,0);
        }
        for (int i=0;i<2;i++) if (v->inventory_arrow_valid[i])
            ui_audit_target(&j,&count,"page",i,0,v->inventory_arrows[i],0,i ? 1 : -1,0);
    }
    ui_audit_add(&j, "]"); uint64_t hash = ui_audit_hash(j.text);
    pthread_mutex_lock(&g_ui_audit_mu);
    if (hash != g_ui_audit_state_hash || frame < g_ui_audit_state_frame || frame-g_ui_audit_state_frame >= 30) {
        g_ui_audit_state_hash=hash; g_ui_audit_state_frame=frame; ui_audit_write("state",frame,&j);
    }
    pthread_mutex_unlock(&g_ui_audit_mu);
}
