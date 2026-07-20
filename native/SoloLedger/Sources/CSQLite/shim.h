#ifndef SOLOLEDGER_CSQLITE_SHIM_H
#define SOLOLEDGER_CSQLITE_SHIM_H

// Bind against the platform's system SQLite (libsqlite3.tbd in the macOS SDK).
// macOS 13's system SQLite is well past 3.31, so generated columns
// (mileage_logs.deduction) and partial indexes are supported.
#include <sqlite3.h>

#endif
