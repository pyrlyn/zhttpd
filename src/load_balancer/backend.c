/* Shared-directory metrics transport. All filesystem I/O stays on this thread.
 * Wire records are ASCII, published with atomic rename, one per worker PID.
 * The directory is a trusted cluster resource, never a public upload directory. */
#include <dirent.h>
#include <fcntl.h>
#include <errno.h>
#include <inttypes.h>
#include <math.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#ifdef __APPLE__
#include <mach/mach.h>
#endif

#define NODES 32
#define MAX_ENTRIES 4096
struct sample {
    uint64_t connections, memory_bytes;
    double cpu;
    uint64_t connection_limit, memory_limit;
    uint32_t cpu_capacity, valid;
    int64_t expires_ms;
};
struct backend {
    char *path, *publish_path, ids[NODES][64], filename[96], temporary[104];
    uint32_t count, local, workers, interval, ttl, cpus;
    uint64_t connections, memory;
    pthread_t thread;
    pthread_mutex_t mutex;
    pthread_cond_t wake;
    int stopping;
    _Atomic uint32_t active;
    _Atomic int64_t heartbeat;
    struct sample snapshots[NODES];
};
static int64_t milliseconds(clockid_t clock) {
    struct timespec ts;
    if (clock_gettime(clock, &ts)) return 0;
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}
static double cpu_seconds(void) {
    struct rusage r;
    if (getrusage(RUSAGE_SELF, &r)) return -1;
    return r.ru_utime.tv_sec + r.ru_stime.tv_sec +
        (r.ru_utime.tv_usec + r.ru_stime.tv_usec) / 1000000.0;
}
static uint64_t resident_bytes(void) {
#ifdef __APPLE__
    struct mach_task_basic_info info;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return 0;
    return info.resident_size;
#elif defined(__linux__)
    FILE *file = fopen("/proc/self/statm", "r");
    if (!file) return 0;
    unsigned long total = 0, resident = 0;
    int fields = fscanf(file, "%lu %lu", &total, &resident);
    fclose(file);
    long page = sysconf(_SC_PAGESIZE);
    return fields == 2 && page > 0 ? (uint64_t)resident * (uint64_t)page : 0;
#else
    return 0; /* Missing current RSS is unavailable, never zero load. */
#endif
}
static int publish(struct backend *b, int dir, int64_t wall, double cpu) {
    uint64_t rss = resident_bytes();
    if (!rss || !isfinite(cpu) || cpu < 0) return 0;
    char record[512];
    int size = snprintf(record, sizeof(record),
        "ZLB1 %" PRId64 " %u %u %" PRIu64 " %.9f %" PRIu64 " %" PRIu64 " %u\n",
        wall, b->workers, atomic_load(&b->active), rss, cpu, b->connections, b->memory, b->cpus);
    if (size < 0 || (size_t)size >= sizeof(record)) return 0;
    int fd = openat(dir, b->temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0) return 0;
    int ok = write(fd, record, (size_t)size) == size;
    if (close(fd)) ok = 0;
    if (ok) ok = renameat(dir, b->temporary, dir, b->filename) == 0;
    if (!ok) unlinkat(dir, b->temporary, 0);
    return ok;
}
static int node_index(struct backend *b, const char *name) {
    for (uint32_t i = 0; i < b->count; i++) {
        size_t len = strlen(b->ids[i]);
        if (strncmp(name, b->ids[i], len) || name[len] != '.') continue;
        const char *pid = name + len + 1;
        if (*pid < '1' || *pid > '9') continue;
        while (*pid >= '0' && *pid <= '9') pid++;
        if (!strcmp(pid, ".load")) return (int)i;
    }
    return -1;
}
static void collect(struct backend *b, int dir, struct sample *out) {
    uint32_t workers[NODES] = {0}, seen[NODES] = {0};
    int bad[NODES] = {0};
    int64_t wall = milliseconds(CLOCK_REALTIME), mono = milliseconds(CLOCK_MONOTONIC);
    DIR *entries = fdopendir(dup(dir));
    if (!entries) return;
    struct dirent *entry;
    unsigned scanned = 0;
    for (;;) {
        errno = 0;
        entry = readdir(entries);
        if (!entry) {
            if (errno) memset(bad, 1, sizeof(bad));
            break;
        }
        if (++scanned > MAX_ENTRIES) { memset(out, 0, NODES * sizeof(*out)); closedir(entries); return; }
        int i = node_index(b, entry->d_name);
        if (i < 0) continue;
        int fd = openat(dir, entry->d_name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
        if (fd < 0) { bad[i] = 1; continue; }
        struct stat st;
        char record[512], extra;
        ssize_t n = -1;
        if (!fstat(fd, &st) && S_ISREG(st.st_mode) && st.st_size > 0 && st.st_size < (off_t)sizeof(record))
            n = read(fd, record, sizeof(record) - 1);
        close(fd);
        if (n <= 0) { bad[i] = 1; continue; }
        record[n] = 0;
        int64_t stamp;
        uint32_t expected, cpus;
        uint64_t active, rss, limit, memory;
        double cpu;
        if (sscanf(record, "ZLB1 %" SCNd64 " %u %" SCNu64 " %" SCNu64 " %lf %" SCNu64 " %" SCNu64 " %u %c",
                &stamp, &expected, &active, &rss, &cpu, &limit, &memory, &cpus, &extra) != 8 ||
            stamp < 0 || expected == 0 || expected > 256 || !rss || !limit || !memory || !cpus ||
            !isfinite(cpu) || cpu < 0 || cpu > 1024 || active > UINT32_MAX || rss > (UINT64_C(1) << 50)) {
            bad[i] = 1; continue;
        }
        if (stamp > wall || wall - stamp >= b->ttl) continue;
        struct sample *s = &out[i];
        if (seen[i] && (workers[i] != expected || s->connection_limit != limit || s->memory_limit != memory || s->cpu_capacity != cpus)) {
            bad[i] = 1; continue;
        }
        int64_t expires = mono + b->ttl - (wall - stamp);
        if (!seen[i] || expires < s->expires_ms) s->expires_ms = expires;
        workers[i] = expected;
        seen[i]++;
        if (seen[i] > 256) { bad[i] = 1; continue; }
        s->connections += active;
        s->memory_bytes += rss;
        s->cpu += cpu;
        s->connection_limit = limit;
        s->memory_limit = memory;
        s->cpu_capacity = cpus;
    }
    closedir(entries);
    for (uint32_t i = 0; i < b->count; i++)
        out[i].valid = !bad[i] && workers[i] && seen[i] >= workers[i];
}
static void *run(void *arg) {
    struct backend *b = arg;
    /* Reclaim a temporary file left by a crashed process with a reused PID.
     * Node IDs must identify exactly one running instance. */
    int initial_dir = open(b->publish_path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (initial_dir >= 0) { unlinkat(initial_dir, b->temporary, 0); close(initial_dir); }
    double previous_cpu = cpu_seconds();
    int64_t previous_time = milliseconds(CLOCK_MONOTONIC);
    for (;;) {
        struct timespec until;
        clock_gettime(CLOCK_REALTIME, &until);
        until.tv_sec += b->interval / 1000;
        until.tv_nsec += (long)(b->interval % 1000) * 1000000;
        if (until.tv_nsec >= 1000000000) { until.tv_sec++; until.tv_nsec -= 1000000000; }
        pthread_mutex_lock(&b->mutex);
        if (!b->stopping) pthread_cond_timedwait(&b->wake, &b->mutex, &until);
        int stop = b->stopping;
        pthread_mutex_unlock(&b->mutex);
        if (stop) break;
        int64_t now = milliseconds(CLOCK_MONOTONIC);
        double current_cpu = cpu_seconds();
        double cpu = previous_cpu >= 0 && current_cpu >= previous_cpu && now > previous_time
            ? (current_cpu - previous_cpu) * 1000 / (now - previous_time) : -1;
        previous_cpu = current_cpu;
        previous_time = now;
        struct sample next[NODES] = {0};
        int output = open(b->publish_path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
        int published = 0;
        if (output >= 0) {
            /* A stalled event loop must not advertise a healthy worker forever. */
            published = now - atomic_load(&b->heartbeat) < b->ttl &&
                publish(b, output, milliseconds(CLOCK_REALTIME), cpu);
            close(output);
        }
        int dir = open(b->path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
        if (dir >= 0) {
            if (published) collect(b, dir, next);
            close(dir);
        }
        pthread_mutex_lock(&b->mutex);
        memcpy(b->snapshots, next, sizeof(next));
        pthread_mutex_unlock(&b->mutex);
    }
    int dir = open(b->publish_path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (dir >= 0) { unlinkat(dir, b->filename, 0); unlinkat(dir, b->temporary, 0); close(dir); }
    return NULL;
}
void *zlb_start(const char *path, const char *publish_path, const char *const *ids, uint32_t count, uint32_t local,
        uint32_t workers, uint32_t interval, uint32_t ttl, uint64_t connections, uint64_t memory, uint32_t cpus) {
    if (count > NODES || local >= count || !workers || workers > 256) return NULL;
    struct backend *b = calloc(1, sizeof(*b));
    if (!b) return NULL;
    b->path = strdup(path);
    b->publish_path = strdup(publish_path);
    if (!b->path || !b->publish_path) { free(b->path); free(b->publish_path); free(b); return NULL; }
    b->count = count; b->local = local; b->workers = workers;
    b->interval = interval; b->ttl = ttl; b->connections = connections; b->memory = memory; b->cpus = cpus;
    for (uint32_t i = 0; i < count; i++) snprintf(b->ids[i], sizeof(b->ids[i]), "%s", ids[i]);
    snprintf(b->filename, sizeof(b->filename), "%s.%ld.load", ids[local], (long)getpid());
    snprintf(b->temporary, sizeof(b->temporary), "%s.tmp", b->filename);
    atomic_init(&b->active, 0);
    atomic_init(&b->heartbeat, milliseconds(CLOCK_MONOTONIC));
    if (pthread_mutex_init(&b->mutex, NULL)) goto free_backend;
    if (pthread_cond_init(&b->wake, NULL)) goto free_mutex;
    sigset_t all, old;
    sigfillset(&all);
    pthread_sigmask(SIG_BLOCK, &all, &old);
    int failed = pthread_create(&b->thread, NULL, run, b);
    pthread_sigmask(SIG_SETMASK, &old, NULL);
    if (!failed) return b;
    pthread_cond_destroy(&b->wake);
free_mutex:
    pthread_mutex_destroy(&b->mutex);
free_backend:
    free(b->path); free(b->publish_path); free(b); return NULL;
}
void zlb_stop(void *handle) {
    struct backend *b = handle;
    pthread_mutex_lock(&b->mutex);
    b->stopping = 1;
    pthread_cond_signal(&b->wake);
    pthread_mutex_unlock(&b->mutex);
    pthread_join(b->thread, NULL);
    pthread_cond_destroy(&b->wake);
    pthread_mutex_destroy(&b->mutex);
    free(b->path); free(b->publish_path); free(b);
}
void zlb_update(void *handle, uint32_t active) {
    struct backend *b = handle;
    atomic_store(&b->active, active);
    atomic_store(&b->heartbeat, milliseconds(CLOCK_MONOTONIC));
}
int zlb_snapshot(void *handle, struct sample *out) {
    struct backend *b = handle;
    if (pthread_mutex_trylock(&b->mutex)) return 0;
    memcpy(out, b->snapshots, b->count * sizeof(*out));
    pthread_mutex_unlock(&b->mutex);
    return 1;
}
