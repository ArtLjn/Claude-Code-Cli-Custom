#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#ifdef _WIN32
  #include <windows.h>
  #define PATH_MAX MAX_PATH
  #define dirname(p) (p)
#else
  #include <unistd.h>
  #include <libgen.h>
#endif

/* 获取可执行文件所在目录 */
static int get_exe_dir(char *buf, size_t size) {
#ifdef __APPLE__
    uint32_t sz = (uint32_t)size;
    if (_NSGetExecutablePath(buf, &sz) != 0) return -1;
    char *dir = dirname(buf);
    memmove(buf, dir, strlen(dir) + 1);
    return 0;
#elif defined(__linux__)
    ssize_t len = readlink("/proc/self/exe", buf, size - 1);
    if (len < 0) return -1;
    buf[len] = '\0';
    /* 去掉最后的文件名，只保留目录 */
    char *last_slash = strrchr(buf, '/');
    if (last_slash) *last_slash = '\0';
    return 0;
#elif defined(_WIN32)
    DWORD len = GetModuleFileNameA(NULL, buf, (DWORD)size);
    if (len == 0 || len == (DWORD)size) return -1;
    char *last_slash = strrchr(buf, '\\');
    if (last_slash) *last_slash = '\0';
    return 0;
#else
    return -1;
#endif
}

int main(int argc, char *argv[]) {
    char exe_dir[4096];
    if (get_exe_dir(exe_dir, sizeof(exe_dir)) != 0) {
        fprintf(stderr, "ocean: cannot resolve executable path\n");
        return 1;
    }

    /* 查找 bun runtime: 优先同目录下的 .ocean-bun */
    char bun_path[4096];
    struct stat st;

#ifdef _WIN32
    snprintf(bun_path, sizeof(bun_path), "%s\\.ocean-bun.exe", exe_dir);
#else
    snprintf(bun_path, sizeof(bun_path), "%s/.ocean-bun", exe_dir);
#endif

    if (stat(bun_path, &st) != 0) {
        /* 回退到 ~/.bun/bin/bun */
        const char *home = getenv("HOME");
        if (home) {
#ifdef _WIN32
            snprintf(bun_path, sizeof(bun_path), "%s\\.bun\\bin\\bun.exe", home);
#else
            snprintf(bun_path, sizeof(bun_path), "%s/.bun/bin/bun", home);
#endif
        }
        if (stat(bun_path, &st) != 0) {
            /* 最后回退到 PATH 中的 bun */
            strcpy(bun_path, "bun");
        }
    }

    /* 构建 bundle 路径 */
    char bundle_path[4096];
#ifdef _WIN32
    snprintf(bundle_path, sizeof(bundle_path), "%s\\.ocean-bundle.js", exe_dir);
#else
    snprintf(bundle_path, sizeof(bundle_path), "%s/.ocean-bundle.js", exe_dir);
#endif

    /* execvp 参数: bun run <bundle> [user args...] */
    int total = argc + 3;
    char **exec_argv = malloc((total + 1) * sizeof(char *));
    exec_argv[0] = bun_path;
    exec_argv[1] = (char *)"run";
    exec_argv[2] = bundle_path;
    for (int i = 1; i < argc; i++) {
        exec_argv[i + 2] = argv[i];
    }
    exec_argv[total] = NULL;

    execvp(bun_path, exec_argv);
    perror("ocean: failed to launch");
    return 127;
}
