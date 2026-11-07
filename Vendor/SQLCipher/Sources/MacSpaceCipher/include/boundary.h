#include "sqlite3.h"
typedef struct msc_boundary msc_boundary;
SQLITE_API msc_boundary *msc_boundary_create(const char *path);
SQLITE_API const char *msc_boundary_name(msc_boundary *);
SQLITE_API void msc_boundary_destroy(msc_boundary *);
SQLITE_API int msc_cipher_key(msc_sqlite3 *, const void *, int);

SQLITE_API int msc_boundary_validate(msc_boundary *);
