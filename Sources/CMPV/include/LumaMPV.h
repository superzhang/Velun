#pragma once
void *luma_create(int headless);
void luma_destroy(void *player);
int luma_load(void *player, const char *path, double start);
int luma_command(void *player, const char *command, const char *argument, const char *argument2);
int luma_set(void *player, const char *name, const char *value);
char *luma_get(void *player, const char *name);
void luma_free(void *value);
int luma_event(void *player, double *number, const char **error);
void *luma_render_create(void *player);
void luma_render(void *render, int width, int height, int floating_point, int framebuffer);
void luma_render_free(void *render);

int luma_render_needs_frame(void *render);

int luma_track_count(const void *node);
long long luma_track_id(const void *node, int index);
const char *luma_track_string(const void *node, int index, const char *key);

double luma_node_number(const void *node, int index, const char *key);
