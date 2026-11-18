#include "LumaMPV.h"
#include <mpv/client.h>
#include <mpv/render_gl.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
void *luma_create(int headless) {
    mpv_handle *p = mpv_create(); if (!p) return NULL;
    mpv_set_option_string(p,"vo",headless ? "null" : "libmpv");
    if(headless) mpv_set_option_string(p,"ao","null");
    mpv_set_option_string(p,"hwdec","auto-safe");
    mpv_set_option_string(p,"config","no");
    // Directory autoload can block on protected folders or stale network mounts.
    // Embedded tracks and explicitly selected external subtitles remain available.
    mpv_set_option_string(p,"autoload-files","no");
    mpv_set_option_string(p,"load-scripts","no");
    mpv_set_option_string(p,"ytdl","no");
    mpv_set_option_string(p,"keep-open","yes");
    mpv_set_option_string(p,"slang","zh-CN,zh,chi,zho,en,eng");
    mpv_set_option_string(p,"sub-pos","80");
    mpv_set_option_string(p,"network-timeout","20");
    mpv_set_option_string(p,"terminal","no");
    const char *debug_log=getenv("LUMA_MPV_LOG");
    if(debug_log) { mpv_set_option_string(p,"log-file",debug_log); mpv_set_option_string(p,"msg-level","all=warn,sub=trace,ass=debug"); }
    if (mpv_initialize(p)<0) { mpv_terminate_destroy(p); return NULL; }
    mpv_observe_property(p,3,"time-pos",MPV_FORMAT_DOUBLE);
    mpv_observe_property(p,4,"duration",MPV_FORMAT_DOUBLE);
    mpv_observe_property(p,5,"pause",MPV_FORMAT_FLAG);
    mpv_observe_property(p,6,"paused-for-cache",MPV_FORMAT_FLAG);
    mpv_observe_property(p,7,"track-list",MPV_FORMAT_NODE);
    mpv_observe_property(p,11,"aid",MPV_FORMAT_STRING);
    mpv_observe_property(p,12,"sid",MPV_FORMAT_STRING);
    mpv_observe_property(p,13,"video-codec",MPV_FORMAT_STRING);
    mpv_observe_property(p,10,"eof-reached",MPV_FORMAT_FLAG);
    mpv_observe_property(p,14,"chapter-list",MPV_FORMAT_NODE);
    mpv_observe_property(p,15,"chapter",MPV_FORMAT_INT64);
    mpv_observe_property(p,16,"width",MPV_FORMAT_DOUBLE);
    mpv_observe_property(p,17,"height",MPV_FORMAT_DOUBLE);
    mpv_observe_property(p,18,"hwdec-current",MPV_FORMAT_STRING);
    mpv_observe_property(p,20,"video-params/gamma",MPV_FORMAT_STRING);
    mpv_observe_property(p,21,"video-params/primaries",MPV_FORMAT_STRING);
    mpv_observe_property(p,22,"audio-codec-name",MPV_FORMAT_STRING);
    mpv_observe_property(p,23,"audio-out-params/channels",MPV_FORMAT_STRING);
    mpv_observe_property(p,24,"audio-out-params/format",MPV_FORMAT_STRING);
    mpv_observe_property(p,25,"current-tracks/video/dolby-vision-profile",MPV_FORMAT_INT64);
    return p;
}
void luma_destroy(void *p) { if (p) mpv_terminate_destroy(p); }
int luma_load(void *p,const char *path,double start) {
    char options[128]; snprintf(options,sizeof(options),"start=%.3f",start);
    const char *args[]={"loadfile",path,"replace","-1",options,NULL};
    return mpv_command_async(p,0,args);
}
int luma_add_external_subtitle(void *player, const char *path) {
    const char *args[] = {"change-list", "sub-files", "append", path, NULL};
    return mpv_command(player, args);
}
int luma_command(void *p,const char *cmd,const char *a,const char *b) { const char *args[]={cmd,a,b,NULL}; return mpv_command_async(p,0,args); }
int luma_set(void *p,const char *name,const char *value) { return mpv_set_property_async(p,0,name,MPV_FORMAT_STRING,&value); }
char *luma_get(void *p,const char *name) { return mpv_get_property_string(p,name); }
void luma_free(void *p) { mpv_free(p); }
int luma_event(void *p,double *number,const char **error) {
    mpv_event *e=mpv_wait_event(p,0);
    if(e->event_id==MPV_EVENT_NONE) return 0;
    if(e->event_id==MPV_EVENT_FILE_LOADED) return 1;
    if(e->event_id==MPV_EVENT_END_FILE) {
        mpv_event_end_file *end=e->data;
        if(end->reason==MPV_END_FILE_REASON_ERROR) { *error=mpv_error_string(end->error); return 2; }
        return 8;
    }
    if((e->event_id==MPV_EVENT_COMMAND_REPLY || e->event_id==MPV_EVENT_SET_PROPERTY_REPLY) && e->error<0) { *error=mpv_error_string(e->error); return 19; }
    if(e->event_id==MPV_EVENT_PROPERTY_CHANGE) {
        mpv_event_property *v=e->data;
        if((e->reply_userdata==7 || e->reply_userdata==14) && v->format==MPV_FORMAT_NODE && v->data) { *error=(const char *)v->data; return (int)e->reply_userdata; }
        if(v->format==MPV_FORMAT_STRING && v->data) { *error=*(const char **)v->data; return (int)e->reply_userdata; }
        if(v->data && v->format==MPV_FORMAT_INT64) { *number=(double)*(int64_t *)v->data; return (int)e->reply_userdata; }
        if(v->data && v->format==MPV_FORMAT_DOUBLE) { *number=*(double *)v->data; return (int)e->reply_userdata; }
        if(v->data && v->format==MPV_FORMAT_FLAG) { *number=*(int *)v->data; return (int)e->reply_userdata; }
    }
    return 9;
}
static void *get_proc(void *context,const char *name) { return dlsym(RTLD_DEFAULT,name); }
void *luma_render_create(void *player) {
    mpv_render_context *r=NULL;
    mpv_opengl_init_params gl={get_proc,NULL};
    mpv_render_param params[]={{MPV_RENDER_PARAM_API_TYPE,MPV_RENDER_API_TYPE_OPENGL},{MPV_RENDER_PARAM_OPENGL_INIT_PARAMS,&gl},{0,NULL}};
    if(mpv_render_context_create(&r,player,params)<0) return NULL;
    return r;
}
void luma_render(void *render,int width,int height,int floating_point,int framebuffer) {
    mpv_opengl_fbo fbo={framebuffer,width,height,floating_point ? 0x881A : 0}; int flip=1; int depth=floating_point ? 16 : 8;
    mpv_render_param params[]={{MPV_RENDER_PARAM_OPENGL_FBO,&fbo},{MPV_RENDER_PARAM_FLIP_Y,&flip},{MPV_RENDER_PARAM_DEPTH,&depth},{0,NULL}};
    mpv_render_context_update(render);
    mpv_render_context_render(render,params);
}
void luma_render_free(void *render) { if(render) mpv_render_context_free(render); }

int luma_render_needs_frame(void *render) { return (mpv_render_context_update(render) & MPV_RENDER_UPDATE_FRAME) != 0; }

int luma_track_count(const void *data) {
    const mpv_node *node=data;
    return node && node->format==MPV_FORMAT_NODE_ARRAY ? node->u.list->num : 0;
}
static const mpv_node *track_field(const void *data,int index,const char *key) {
    const mpv_node *root=data;
    if(index<0 || index>=luma_track_count(data)) return NULL;
    const mpv_node *entry=&root->u.list->values[index];
    if(entry->format!=MPV_FORMAT_NODE_MAP) return NULL;
    for(int i=0;i<entry->u.list->num;i++) if(strcmp(entry->u.list->keys[i],key)==0) return &entry->u.list->values[i];
    return NULL;
}
long long luma_track_id(const void *data,int index) {
    const mpv_node *v=track_field(data,index,"id"); return v && v->format==MPV_FORMAT_INT64 ? v->u.int64 : -1;
}
const char *luma_track_string(const void *data,int index,const char *key) {
    const mpv_node *v=track_field(data,index,key); return v && v->format==MPV_FORMAT_STRING ? v->u.string : "";
}

double luma_node_number(const void *data,int index,const char *key) {
    const mpv_node *v=track_field(data,index,key);
    if(!v) return 0;
    return v->format==MPV_FORMAT_DOUBLE ? v->u.double_ : v->format==MPV_FORMAT_INT64 ? (double)v->u.int64 : 0;
}

int luma_prefer_external_subtitle(void *player, const char *path) {
    mpv_node tracks;
    if (mpv_get_property(player, "track-list", MPV_FORMAT_NODE, &tracks) < 0) return 0;
    int64_t preferred_id = 0;
    int keep_selection = 0;
    for (int i = 0; i < luma_track_count(&tracks); i++) {
        if (strcmp(luma_track_string(&tracks, i, "type"), "sub") != 0) continue;
        const char *external = luma_track_string(&tracks, i, "external-filename");
        int matches_path = strcmp(external, path) == 0;
        const mpv_node *selected = track_field(&tracks, i, "selected");
        if (selected && selected->format == MPV_FORMAT_FLAG && selected->u.flag &&
            (!*external || matches_path)) keep_selection = 1;
        if (matches_path) preferred_id = luma_track_id(&tracks, i);
    }
    mpv_free_node_contents(&tracks);

    if (keep_selection) return 1;
    return preferred_id > 0 && mpv_set_property_async(player, 0, "sid", MPV_FORMAT_INT64, &preferred_id) >= 0;
}
