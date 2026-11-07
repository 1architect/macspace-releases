#include "include/boundary.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>
// A connection exclusively owns its main inode for its entire lifetime. This
// permits private in-memory WAL indexing, with no pathname-opened shared-memory
// files.
struct msc_boundary {
    sqlite3_vfs vfs;
    char name[64], leaf[NAME_MAX + 1];
    int dirs[PATH_MAX / 2], count, mainfd;
    char parts[PATH_MAX / 2][NAME_MAX + 1];
    struct stat identities[PATH_MAX / 2], main;
    struct stat sidecars[2];
    int sidecarPresent[2];
    void *shm[64];
    int shmSize;
    struct msc_boundary *next;
    int refs, readers;
    void *reserved, *pending, *exclusive;
    pthread_mutex_t mutex;
    int shmReaders[SQLITE_SHM_NLOCK];
    void *shmWriters[SQLITE_SHM_NLOCK];
};
typedef struct {
    sqlite3_file base;
    msc_boundary *owner;
    int fd, main;
    char leaf[NAME_MAX + 16];
    struct stat identity;
    int level;
    unsigned shmShared, shmExclusive;
} File;
static pthread_mutex_t registryMutex = PTHREAD_MUTEX_INITIALIZER;
static msc_boundary *registry = 0;
static int ioUnlock(sqlite3_file *, int);
static int ioShmLock(sqlite3_file *, int, int, int);
static int same(struct stat *a, struct stat *b) {
    return a->st_dev == b->st_dev && a->st_ino == b->st_ino &&
           a->st_uid == b->st_uid;
}
static int safe(struct stat *s) {
    return S_ISREG(s->st_mode) && s->st_uid == getuid() && s->st_nlink == 1 &&
           !(s->st_mode & 077) &&
           !(s->st_flags & (UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND |
                            SF_APPEND | SF_DATALESS | SF_RESTRICTED));
}
static int valid(msc_boundary *b) {
    struct stat s;
    for (int i = 1; i < b->count; i++)
        if (fstatat(b->dirs[i - 1], b->parts[i], &s, AT_SYMLINK_NOFOLLOW) ||
            !S_ISDIR(s.st_mode) || !same(&s, &b->identities[i]))
            return 0;
    return !fstatat(b->dirs[b->count - 1], b->leaf, &s, AT_SYMLINK_NOFOLLOW) &&
           safe(&s) && same(&s, &b->main);
}
static int fileValid(File *f) {
    struct stat s;
    return !fstatat(f->owner->dirs[f->owner->count - 1], f->leaf, &s,
                    AT_SYMLINK_NOFOLLOW) &&
           safe(&s) && same(&s, &f->identity);
}
static int ioClose(sqlite3_file *p) {
    File *f = (File *)p;
    ioShmLock(p, 0, SQLITE_SHM_NLOCK, SQLITE_SHM_UNLOCK | SQLITE_SHM_SHARED);
    ioUnlock(p, SQLITE_LOCK_NONE);
    close(f->fd);
    f->base.pMethods = 0;
    return SQLITE_OK;
}
static int ioRead(sqlite3_file *p, void *out, int n, sqlite3_int64 off) {
    File *f = (File *)p;
    if (!fileValid(f))
        return SQLITE_IOERR_READ;
    ssize_t r;
    do {
        r = pread(f->fd, out, n, off);
    } while (r < 0 && errno == EINTR);
    if (r == n)
        return SQLITE_OK;
    if (r >= 0) {
        memset((char *)out + r, 0, n - r);
        return SQLITE_IOERR_SHORT_READ;
    }
    return SQLITE_IOERR_READ;
}
static int ioWrite(sqlite3_file *p, const void *in, int n, sqlite3_int64 off) {
    File *f = (File *)p;
    if (!fileValid(f))
        return SQLITE_IOERR_WRITE;
    int done = 0;
    while (done < n) {
        ssize_t r =
            pwrite(f->fd, (const char *)in + done, n - done, off + done);
        if (r < 0 && errno == EINTR)
            continue;
        if (r <= 0)
            return SQLITE_IOERR_WRITE;
        done += (int)r;
    }
    return SQLITE_OK;
}
static int ioTruncate(sqlite3_file *p, sqlite3_int64 size) {
    File *f = (File *)p;
    return fileValid(f) && !ftruncate(f->fd, size) ? SQLITE_OK
                                                   : SQLITE_IOERR_TRUNCATE;
}
static int ioSync(sqlite3_file *p, int flags) {
    File *f = (File *)p;
    return fileValid(f) && !fsync(f->fd) ? SQLITE_OK : SQLITE_IOERR_FSYNC;
}
static int ioSize(sqlite3_file *p, sqlite3_int64 *out) {
    File *f = (File *)p;
    struct stat s;
    if (!fileValid(f) || fstat(f->fd, &s))
        return SQLITE_IOERR_FSTAT;
    *out = s.st_size;
    return SQLITE_OK;
}
static int ioLock(sqlite3_file *p, int n) {
    File *f = (File *)p;
    msc_boundary *b = f->owner;
    if (!fileValid(f))
        return SQLITE_IOERR_LOCK;
    pthread_mutex_lock(&b->mutex);
    int rc = SQLITE_OK;
    if (n > f->level) {
        if (n == SQLITE_LOCK_SHARED) {
            if (b->exclusive || b->pending)
                rc = SQLITE_BUSY;
            else {
                b->readers++;
                f->level = n;
            }
        } else if (n == SQLITE_LOCK_RESERVED) {
            if (b->reserved && b->reserved != f)
                rc = SQLITE_BUSY;
            else {
                b->reserved = f;
                f->level = n;
            }
        } else if (n == SQLITE_LOCK_EXCLUSIVE) {
            if ((b->pending && b->pending != f) ||
                (b->reserved && b->reserved != f))
                rc = SQLITE_BUSY;
            else {
                b->pending = f;
                if (b->readers > (f->level >= SQLITE_LOCK_SHARED ? 1 : 0))
                    rc = SQLITE_BUSY;
                else {
                    b->exclusive = f;
                    f->level = n;
                }
            }
        } else if (n == SQLITE_LOCK_PENDING) {
            if (b->pending && b->pending != f)
                rc = SQLITE_BUSY;
            else {
                b->pending = f;
                f->level = n;
            }
        }
    }
    pthread_mutex_unlock(&b->mutex);
    return rc;
}
static int ioUnlock(sqlite3_file *p, int n) {
    File *f = (File *)p;
    msc_boundary *b = f->owner;
    pthread_mutex_lock(&b->mutex);
    if (n <= SQLITE_LOCK_SHARED) {
        if (b->reserved == f)
            b->reserved = 0;
        if (b->pending == f)
            b->pending = 0;
        if (b->exclusive == f)
            b->exclusive = 0;
    }
    if (n == SQLITE_LOCK_NONE && f->level >= SQLITE_LOCK_SHARED)
        b->readers--;
    f->level = n;
    pthread_mutex_unlock(&b->mutex);
    return SQLITE_OK;
}
static int ioReserved(sqlite3_file *p, int *out) {
    File *f = (File *)p;
    pthread_mutex_lock(&f->owner->mutex);
    *out = f->owner->reserved != 0;
    pthread_mutex_unlock(&f->owner->mutex);
    return SQLITE_OK;
}
static int ioControl(sqlite3_file *p, int op, void *out) {
    if (op == SQLITE_FCNTL_LOCKSTATE) {
        *(int *)out = ((File *)p)->level;
        return SQLITE_OK;
    }
    return SQLITE_NOTFOUND;
}
static int ioSector(sqlite3_file *p) { return 4096; }
static int ioDevice(sqlite3_file *p) { return 0; }
static int ioShmMap(sqlite3_file *p, int page, int size, int extend,
                    void volatile **out) {
    File *f = (File *)p;
    msc_boundary *b = f->owner;
    if (!fileValid(f) || page < 0 || page >= 64 || size <= 0)
        return SQLITE_IOERR_SHMMAP;
    pthread_mutex_lock(&b->mutex);
    if (b->shmSize && b->shmSize != size) {
        pthread_mutex_unlock(&b->mutex);
        return SQLITE_IOERR_SHMMAP;
    }
    b->shmSize = size;
    if (!b->shm[page] && extend)
        b->shm[page] = calloc(1, size);
    *out = b->shm[page];
    pthread_mutex_unlock(&b->mutex);
    return extend && !*out ? SQLITE_NOMEM : SQLITE_OK;
}
static int ioShmLock(sqlite3_file *p, int off, int n, int flags) {
    File *f = (File *)p;
    msc_boundary *b = f->owner;
    if (off < 0 || n < 1 || off + n > SQLITE_SHM_NLOCK)
        return SQLITE_IOERR_SHMLOCK;
    pthread_mutex_lock(&b->mutex);
    int rc = SQLITE_OK;
    if (flags & SQLITE_SHM_UNLOCK) {
        for (int i = off; i < off + n; i++) {
            unsigned bit = 1u << i;
            if (f->shmShared & bit) {
                b->shmReaders[i]--;
                f->shmShared &= ~bit;
            }
            if (f->shmExclusive & bit) {
                b->shmWriters[i] = 0;
                f->shmExclusive &= ~bit;
            }
        }
    } else {
        for (int i = off; i < off + n; i++) {
            if ((b->shmWriters[i] && b->shmWriters[i] != f) ||
                ((flags & SQLITE_SHM_EXCLUSIVE) &&
                 b->shmReaders[i] > (!!(f->shmShared & (1u << i))))) {
                rc = SQLITE_BUSY;
                break;
            }
        }
        if (rc == SQLITE_OK)
            for (int i = off; i < off + n; i++) {
                unsigned bit = 1u << i;
                if (flags & SQLITE_SHM_EXCLUSIVE) {
                    b->shmWriters[i] = f;
                    f->shmExclusive |= bit;
                } else if (!(f->shmShared & bit)) {
                    b->shmReaders[i]++;
                    f->shmShared |= bit;
                }
            }
    }
    pthread_mutex_unlock(&b->mutex);
    return rc;
}
static void ioBarrier(sqlite3_file *p) { __sync_synchronize(); }
static int ioShmUnmap(sqlite3_file *p, int del) {
    return ioShmLock(p, 0, SQLITE_SHM_NLOCK,
                     SQLITE_SHM_UNLOCK | SQLITE_SHM_SHARED);
}
static const sqlite3_io_methods methods = {
    2,         ioClose,   ioRead,     ioWrite,   ioTruncate, ioSync,   ioSize,
    ioLock,    ioUnlock,  ioReserved, ioControl, ioSector,   ioDevice, ioShmMap,
    ioShmLock, ioBarrier, ioShmUnmap, 0,         0};
static const char *leafFor(msc_boundary *b, const char *path) {
    if (!path)
        return 0;
    const char *leaf = strrchr(path, '/');
    leaf = leaf ? leaf + 1 : path;
    size_t n = strlen(b->leaf);
    if (strncmp(leaf, b->leaf, n))
        return 0;
    const char *s = leaf + n;
    return !*s || !strcmp(s, "-wal") || !strcmp(s, "-journal") ? leaf : 0;
}
static int sidecarSlot(msc_boundary *b, const char *leaf) {
    if (!strcmp(leaf, b->leaf))
        return -1;
    return !strcmp(leaf + strlen(b->leaf), "-wal") ? 0 : 1;
}
static int vOpenInner(sqlite3_vfs *v, const char *path, sqlite3_file *p,
                      int flags, int *out) {
    msc_boundary *b = v->pAppData;
    File *f = (File *)p;
    memset(f, 0, sizeof(*f));
    f->fd = -1;
    const char *leaf = leafFor(b, path);
    if (!leaf || !valid(b) ||
        (flags & (SQLITE_OPEN_DELETEONCLOSE | SQLITE_OPEN_TEMP_DB |
                  SQLITE_OPEN_TEMP_JOURNAL | SQLITE_OPEN_SUBJOURNAL |
                  SQLITE_OPEN_SUPER_JOURNAL)))
        return SQLITE_CANTOPEN;
    int slot = sidecarSlot(b, leaf), main = slot < 0, fd = -1;
    if (main)
        fd = fcntl(b->mainfd, F_DUPFD_CLOEXEC, 0);
    else if (b->sidecarPresent[slot])
        fd = openat(b->dirs[b->count - 1], leaf,
                    O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    else if (flags & SQLITE_OPEN_CREATE)
        fd = openat(b->dirs[b->count - 1], leaf,
                    O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    struct stat value;
    if (fd < 0)
        return SQLITE_CANTOPEN;
    if (fstat(fd, &value) || !safe(&value) || value.st_dev != b->main.st_dev ||
        (!main && b->sidecarPresent[slot] &&
         !same(&value, &b->sidecars[slot]))) {
        close(fd);
        return SQLITE_CANTOPEN;
    }
    f->fd = fd;
    f->owner = b;
    f->main = main;
    f->identity = value;
    strlcpy(f->leaf, leaf, sizeof(f->leaf));
    if (!fileValid(f)) {
        close(fd);
        return SQLITE_CANTOPEN;
    }
    if (!main) {
        b->sidecars[slot] = value;
        b->sidecarPresent[slot] = 1;
    }
    f->base.pMethods = &methods;
    if (out)
        *out = SQLITE_OPEN_READWRITE;
    return SQLITE_OK;
}
static int vOpen(sqlite3_vfs *v, const char *path, sqlite3_file *p, int flags,
                 int *out) {
    msc_boundary *b = v->pAppData;
    pthread_mutex_lock(&b->mutex);
    int result = vOpenInner(v, path, p, flags, out);
    pthread_mutex_unlock(&b->mutex);
    return result;
}
static int vDeleteInner(sqlite3_vfs *v, const char *path, int sync) {
    msc_boundary *b = v->pAppData;
    const char *leaf = leafFor(b, path);
    struct stat before, after;
    int dir = b->dirs[b->count - 1];
    if (!leaf || !strcmp(leaf, b->leaf) || !valid(b))
        return SQLITE_IOERR_DELETE;
    int slot = sidecarSlot(b, leaf);
    if (fstatat(dir, leaf, &before, AT_SYMLINK_NOFOLLOW))
        return errno == ENOENT && !b->sidecarPresent[slot]
                   ? SQLITE_OK
                   : SQLITE_IOERR_DELETE;
    if (!safe(&before) || !b->sidecarPresent[slot] ||
        !same(&before, &b->sidecars[slot]))
        return SQLITE_IOERR_DELETE;
    char stage[80];
    snprintf(stage, sizeof(stage), ".retired-%08x-%08x", arc4random(),
             arc4random());
    if (renameatx_np(dir, leaf, dir, stage, RENAME_EXCL))
        return SQLITE_IOERR_DELETE;
    if (fstatat(dir, stage, &after, AT_SYMLINK_NOFOLLOW) ||
        !same(&before, &after) || !safe(&after))
        return SQLITE_IOERR_DELETE;
    if (unlinkat(dir, stage, 0))
        return SQLITE_IOERR_DELETE;
    b->sidecarPresent[slot] = 0;
    return !sync || !fsync(dir) ? SQLITE_OK : SQLITE_IOERR_DIR_FSYNC;
}
static int vDelete(sqlite3_vfs *v, const char *path, int sync) {
    msc_boundary *b = v->pAppData;
    pthread_mutex_lock(&b->mutex);
    int result = vDeleteInner(v, path, sync);
    pthread_mutex_unlock(&b->mutex);
    return result;
}
static int vAccessInner(sqlite3_vfs *v, const char *path, int flags, int *out) {
    msc_boundary *b = v->pAppData;
    const char *leaf = leafFor(b, path);
    struct stat value;
    *out = 0;
    if (!leaf || !valid(b))
        return SQLITE_IOERR_ACCESS;
    int slot = sidecarSlot(b, leaf);
    if (fstatat(b->dirs[b->count - 1], leaf, &value, AT_SYMLINK_NOFOLLOW))
        return errno == ENOENT && (slot < 0 || !b->sidecarPresent[slot])
                   ? SQLITE_OK
                   : SQLITE_IOERR_ACCESS;
    if (!safe(&value) || value.st_dev != b->main.st_dev ||
        (slot >= 0 &&
         (!b->sidecarPresent[slot] || !same(&value, &b->sidecars[slot]))))
        return SQLITE_IOERR_ACCESS;
    *out = 1;
    return SQLITE_OK;
}
static int vAccess(sqlite3_vfs *v, const char *path, int flags, int *out) {
    msc_boundary *b = v->pAppData;
    pthread_mutex_lock(&b->mutex);
    int result = vAccessInner(v, path, flags, out);
    pthread_mutex_unlock(&b->mutex);
    return result;
}
static int vFull(sqlite3_vfs *v, const char *path, int n, char *out) {
    msc_boundary *b = v->pAppData;
    const char *leaf = leafFor(b, path);
    if (!leaf || strlen(leaf) + 2 > (size_t)n)
        return SQLITE_CANTOPEN;
    snprintf(out, n, "/%s", leaf);
    return SQLITE_OK;
}
static int vRandom(sqlite3_vfs *v, int n, char *out) {
    arc4random_buf(out, n);
    return n;
}
static int vSleep(sqlite3_vfs *v, int n) {
    usleep(n);
    return n;
}
static int vTime(sqlite3_vfs *v, double *out) {
    struct timeval t;
    gettimeofday(&t, 0);
    *out = 2440587.5 + (t.tv_sec + t.tv_usec / 1e6) / 86400.;
    return SQLITE_OK;
}
msc_boundary *msc_boundary_create(const char *path) {
    if (!path || path[0] != '/' || strlen(path) >= PATH_MAX || getuid() == 0 ||
        geteuid() != getuid())
        return 0;
    msc_boundary *b = calloc(1, sizeof(*b));
    if (!b)
        return 0;
    b->mainfd = -1;
    pthread_mutex_init(&b->mutex, 0);
    char copy[PATH_MAX];
    strlcpy(copy, path, sizeof(copy));
    char *last = strrchr(copy, '/');
    strlcpy(b->leaf, last + 1, sizeof(b->leaf));
    *last = 0;
    b->dirs[0] = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (b->dirs[0] < 0)
        goto fail;
    b->count = 1;
    fstat(b->dirs[0], &b->identities[0]);
    char *save = 0;
    for (char *part = strtok_r(copy, "/", &save); part;
         part = strtok_r(0, "/", &save)) {
        int i = b->count;
        if (!strcmp(part, ".") || !strcmp(part, "..") ||
            strlen(part) > NAME_MAX)
            goto fail;
        int fd = openat(b->dirs[i - 1], part,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (fd < 0)
            goto fail;
        b->dirs[i] = fd;
        strlcpy(b->parts[i], part, sizeof(b->parts[i]));
        b->count++;
        struct stat *s = &b->identities[i];
        if (fstat(fd, s) || (s->st_uid != 0 && s->st_uid != getuid()) ||
            ((s->st_mode & 022) && !(s->st_uid == 0 && (s->st_mode & S_ISVTX))))
            goto fail;
    }
    int dir = b->dirs[b->count - 1];
    struct statfs fs;
    if (b->identities[b->count - 1].st_uid != getuid() || fstatfs(dir, &fs) ||
        !(fs.f_flags & MNT_LOCAL) || (fs.f_flags & MNT_RDONLY) ||
        (b->count > 1 && b->identities[b->count - 1].st_dev !=
                             b->identities[b->count - 2].st_dev))
        goto fail;
    b->mainfd =
        openat(dir, b->leaf, O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    if (b->mainfd < 0 || fstat(b->mainfd, &b->main) || !safe(&b->main) ||
        b->main.st_dev != b->identities[b->count - 1].st_dev)
        goto fail;
    if (!valid(b))
        goto fail;
    for (int slot = 0; slot < 2; slot++) {
        char sidecar[NAME_MAX + 16];
        snprintf(sidecar, sizeof(sidecar), "%s%s", b->leaf,
                 slot == 0 ? "-wal" : "-journal");
        if (!fstatat(dir, sidecar, &b->sidecars[slot], AT_SYMLINK_NOFOLLOW)) {
            if (!safe(&b->sidecars[slot]) ||
                b->sidecars[slot].st_dev != b->main.st_dev)
                goto fail;
            b->sidecarPresent[slot] = 1;
        } else if (errno != ENOENT)
            goto fail;
    }
    pthread_mutex_lock(&registryMutex);
    for (msc_boundary *existing = registry; existing; existing = existing->next)
        if (same(&b->main, &existing->main)) {
            if (!valid(existing)) {
                pthread_mutex_unlock(&registryMutex);
                goto fail;
            }
            existing->refs++;
            pthread_mutex_unlock(&registryMutex);
            msc_boundary_destroy(b);
            return existing;
        }
    if (flock(b->mainfd, LOCK_EX | LOCK_NB)) {
        pthread_mutex_unlock(&registryMutex);
        goto fail;
    }
    b->refs = 1;
    b->next = registry;
    registry = b;
    pthread_mutex_unlock(&registryMutex);
    snprintf(b->name, sizeof(b->name), "macspace-%08x-%08x", arc4random(),
             arc4random());
    b->vfs = (sqlite3_vfs){.iVersion = 1,
                           .szOsFile = sizeof(File),
                           .mxPathname = PATH_MAX,
                           .zName = b->name,
                           .pAppData = b,
                           .xOpen = vOpen,
                           .xDelete = vDelete,
                           .xAccess = vAccess,
                           .xFullPathname = vFull,
                           .xRandomness = vRandom,
                           .xSleep = vSleep,
                           .xCurrentTime = vTime};
    if (sqlite3_vfs_register(&b->vfs, 0) != SQLITE_OK)
        goto fail;
    return b;
fail:
    msc_boundary_destroy(b);
    return 0;
}
const char *msc_boundary_name(msc_boundary *b) { return b ? b->name : 0; }
void msc_boundary_destroy(msc_boundary *b) {
    if (!b)
        return;
    pthread_mutex_lock(&registryMutex);
    if (b->refs > 1) {
        b->refs--;
        pthread_mutex_unlock(&registryMutex);
        return;
    }
    msc_boundary **slot = &registry;
    while (*slot && *slot != b)
        slot = &(*slot)->next;
    if (*slot == b)
        *slot = b->next;
    pthread_mutex_unlock(&registryMutex);
    if (b->vfs.zName)
        sqlite3_vfs_unregister(&b->vfs);
    if (b->mainfd >= 0)
        close(b->mainfd);
    for (int i = b->count - 1; i >= 0; i--)
        close(b->dirs[i]);
    for (int i = 0; i < 64; i++)
        free(b->shm[i]);
    pthread_mutex_destroy(&b->mutex);
    free(b);
}
int msc_cipher_key(sqlite3 *db, const void *key, int size) {
    if (!key || size != 32)
        return SQLITE_MISUSE;
    char literal[68];
    const char *hex = "0123456789abcdef";
    literal[0] = 'x';
    literal[1] = '\'';
    for (int i = 0; i < 32; i++) {
        unsigned char byte = ((const unsigned char *)key)[i];
        literal[2 + 2 * i] = hex[byte >> 4];
        literal[3 + 2 * i] = hex[byte & 15];
    }
    literal[66] = '\'';
    literal[67] = 0;
    int result = sqlite3_key(db, literal, 67);
    for (volatile char *w = literal; w < literal + sizeof(literal); w++)
        *w = 0;
    return result;
}

int msc_boundary_validate(msc_boundary *b) { return b && valid(b); }
