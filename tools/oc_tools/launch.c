/*
 * SubMac's command launcher for opencode's shell on Android (2026-11-02).
 *
 * Android lets an app execute only files in its nativeLibraryDir, and Android has no musl loader at /lib, so the
 * command-line tools SubMac ships (git, curl, python3, ripgrep, busybox applets...) cannot be run directly. Every
 * name in $OC_BIN is a symlink to this one static binary (libsmx_launch.so). It looks its own name up in
 * $OC_ROOT/bin.tsv ("name<TAB>path-in-root<TAB>optional busybox applet") and then:
 *   - an ELF: runs it through musl's loader ($OC_LD --library-path $OC_LIBS --argv0 <name as called> <file> ...;
 *     a busybox applet gets the applet as argv[0], which is how busybox picks it),
 *   - a script with #!: runs its interpreter (sh -> /system/bin/sh, anything else -> $OC_BIN/<interpreter>),
 *   - anything else: /system/bin/sh <file> ...
 * Built static for arm64 in CI (tools/oc_tools/bundle.py).
 */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const char *base(const char *p) {
  const char *s = strrchr(p, '/');
  return s ? s + 1 : p;
}

static void die(const char *what, const char *name) {
  fprintf(stderr, "%s: %s\n", name, what);
  exit(127);
}

/* Finds [name] in bin.tsv: fills [rel] and [applet] (empty when none). */
static int lookup(const char *root, const char *name, char *rel, size_t reln, char *applet, size_t appn) {
  char path[4096];
  snprintf(path, sizeof path, "%s/bin.tsv", root);
  FILE *f = fopen(path, "r");
  if (!f) return 0;
  char line[8192];
  int found = 0;
  while (fgets(line, sizeof line, f)) {
    line[strcspn(line, "\r\n")] = 0;
    char *a = strtok(line, "\t");
    char *b = strtok(NULL, "\t");
    char *c = strtok(NULL, "\t");
    if (!a || !b || strcmp(a, name) != 0) continue;
    snprintf(rel, reln, "%s", b);
    snprintf(applet, appn, "%s", c ? c : "");
    found = 1;
    break;
  }
  fclose(f);
  return found;
}

int main(int argc, char **argv) {
  const char *name = base(argv[0]);
  const char *root = getenv("OC_ROOT");
  const char *ld = getenv("OC_LD");
  const char *libs = getenv("OC_LIBS");
  const char *bin = getenv("OC_BIN");
  if (!root || !ld || !libs || !bin) die("SubMac tools are not set up (OC_ROOT, OC_LD, OC_LIBS, OC_BIN)", name);

  char rel[4096], applet[256];
  if (!lookup(root, name, rel, sizeof rel, applet, sizeof applet)) die("command not found", name);
  char file[8192];
  snprintf(file, sizeof file, "%s/%s", root, rel);

  unsigned char head[512];
  memset(head, 0, sizeof head);
  int fd = open(file, O_RDONLY);
  if (fd < 0) die(strerror(errno), name);
  ssize_t n = read(fd, head, sizeof head - 1);
  close(fd);
  if (n < 0) n = 0;

  char **nv = calloc((size_t)argc + 8, sizeof(char *));
  if (!nv) die("out of memory", name);
  int k = 0;

  if (n >= 4 && head[0] == 0x7f && head[1] == 'E' && head[2] == 'L' && head[3] == 'F') {
    nv[k++] = (char *)ld;
    nv[k++] = "--library-path";
    nv[k++] = (char *)libs;
    nv[k++] = "--argv0";
    /* busybox picks its applet from argv[0]. */
    nv[k++] = applet[0] ? applet : argv[0];
    nv[k++] = file;
    for (int i = 1; i < argc; i++) nv[k++] = argv[i];
    nv[k] = NULL;
    execv(ld, nv);
    die(strerror(errno), name);
  }

  if (n >= 2 && head[0] == '#' && head[1] == '!') {
    char *l = (char *)head + 2;
    l[strcspn(l, "\r\n")] = 0;
    while (*l == ' ' || *l == '\t') l++;
    char *interp = strtok(l, " \t");
    char *opt = strtok(NULL, "");
    if (opt) {
      while (*opt == ' ' || *opt == '\t') opt++;
      if (!*opt) opt = NULL;
    }
    const char *ib = interp ? base(interp) : "sh";
    if (strcmp(ib, "env") == 0 && opt) {
      char *o = strtok(opt, " \t");
      ib = o ? o : "sh";
      opt = strtok(NULL, "");
    }
    static char prog[8192];
    if (strcmp(ib, "sh") == 0 || strcmp(ib, "bash") == 0 || strcmp(ib, "ash") == 0) {
      snprintf(prog, sizeof prog, "/system/bin/sh");
      opt = NULL;
    } else {
      snprintf(prog, sizeof prog, "%s/%s", bin, ib);
    }
    nv[k++] = prog;
    if (opt) nv[k++] = opt;
    nv[k++] = file;
    for (int i = 1; i < argc; i++) nv[k++] = argv[i];
    nv[k] = NULL;
    execv(prog, nv);
    die(strerror(errno), name);
  }

  nv[k++] = "/system/bin/sh";
  nv[k++] = file;
  for (int i = 1; i < argc; i++) nv[k++] = argv[i];
  nv[k] = NULL;
  execv("/system/bin/sh", nv);
  die(strerror(errno), name);
  return 127;
}
