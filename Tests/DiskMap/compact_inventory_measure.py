"""Isolated SQLite storage/write-cost fixture. Does not build, launch, or scan MacSpace.
Run from the repository root: python3 Tests/DiskMap/compact_inventory_measure.py
Synthetic assumptions are printed; results are not a live filesystem benchmark.
"""
import json
from pathlib import Path
import re
import sqlite3
import tempfile
import time

ENGINE = Path(__file__).resolve().parents[2] / "Modules/DiskMap/Module/Engine"
SCHEMA = (ENGINE / "DiskDatabase.swift").read_text()
SELECTION = (ENGINE / "DiskDatabaseSummaries.swift").read_text()


def compact(connection):
    for sql in re.findall(r'try execute\("(CREATE TABLE[^"\n]*)"\)', SCHEMA):
        connection.execute(sql)
    for name, columns in re.findall(r'\("([a-z_]+)", "((?:dirs|entries)\([^"\n]+)"\)', SCHEMA):
        connection.execute("CREATE INDEX " + name + " ON " + columns)


with tempfile.TemporaryDirectory(prefix="macspace-compact-measure-") as temporary:
    base = Path(temporary)
    old, new = sqlite3.connect(base / "legacy.sqlite"), sqlite3.connect(base / "compact.sqlite")
    old.executescript("""
        CREATE TABLE dirs(path TEXT PRIMARY KEY,parent TEXT NOT NULL,direct INTEGER,total INTEGER,readable INTEGER,uid INTEGER,bundle TEXT) WITHOUT ROWID;
        CREATE TABLE files(path TEXT PRIMARY KEY,parent TEXT,bytes INTEGER,logical INTEGER,uid INTEGER,link TEXT) WITHOUT ROWID;
        CREATE TABLE file_details(path TEXT PRIMARY KEY,parent TEXT,bytes INTEGER,logical INTEGER,uid INTEGER,link TEXT,category TEXT,modified INTEGER,kind TEXT) WITHOUT ROWID;
        CREATE INDEX dirs_parent ON dirs(parent);
        CREATE INDEX dirs_depth ON dirs(length(path) DESC,path);
        CREATE INDEX dirs_apps ON dirs(path,total) WHERE substr(path,-4)='.app';
        CREATE INDEX dirs_bundles ON dirs(bundle) WHERE bundle<>'';
        CREATE INDEX files_parent ON files(parent);
        CREATE INDEX files_links ON files(link,path) WHERE link<>'';
        CREATE INDEX details_parent ON file_details(parent,logical DESC,path);
        CREATE INDEX details_links ON file_details(link,path) WHERE link<>'';
        CREATE INDEX details_large ON file_details(logical DESC,path) WHERE logical>=100000000 AND bytes>0;
    """)
    compact(new)
    folders = [f"/Users/fixture/Downloads/Project-{n:04}/nested/output" for n in range(1000)]
    for n, folder in enumerate(folders):
        old.execute("INSERT INTO dirs VALUES(?,?,?,?,?,?,?)", (folder, folder.rsplit("/", 1)[0], 409600, 409600, 1, 501, ""))
        new.execute("INSERT INTO dirs VALUES(?,?,?,?,?,?,?,?)", (n + 1, folder, 0, 409600, 409600, 1, 501, ""))
    for n in range(100000):
        parent, name = folders[n % 1000], f"document-{n:06}.zip"
        logical, link = (100000000 if n % 100 == 0 else 8192), (f"501:{n//2}" if n % 100 in (1, 2) else "")
        detail = (parent + "/" + name, parent, 4096, logical, 501, link, "archives", 1700000000, "archive")
        old.execute("INSERT INTO file_details VALUES(?,?,?,?,?,?,?,?,?)", detail)
        if link or logical >= 100000000:
            old.execute("INSERT INTO files VALUES(?,?,?,?,?,?)", detail[:6])
            new.execute("INSERT INTO entries VALUES(?,?,?,?,?,?,?,?,?,?)", (n % 1000 + 1, name, 4096, logical, 501, link, "archives", 1700000000, "", int(logical >= 100000000)))
    for database in (old, new):
        database.commit()
        database.execute("VACUUM")
    before, after = (base / "legacy.sqlite").stat().st_size, (base / "compact.sqlite").stat().st_size
    print(json.dumps(dict(fixture="100000 files, 1000 directories, 1% large, 2% hardlink names", legacyBytes=before, compactBytes=after, reductionPercent=round(100 * (1 - after / before), 2))))

    directory_bytes = {}
    for mode in ("text", "integer"):
        path = base / (mode + ".sqlite")
        database = sqlite3.connect(path)
        database.execute("CREATE TABLE dirs(id INTEGER PRIMARY KEY,path TEXT UNIQUE,parent " + mode + ",direct INTEGER,total INTEGER,readable INTEGER,uid INTEGER,bundle TEXT)")
        database.execute("CREATE INDEX dirs_parent ON dirs(parent)")
        database.execute("CREATE INDEX dirs_depth ON dirs(length(path) DESC,path)")
        for n in range(100000):
            parent = f"/Users/fixture/Downloads/Project-{n//100:05}/nested/output"
            database.execute("INSERT INTO dirs VALUES(?,?,?,?,?,?,?,?)", (n + 1, parent + f"/directory-{n:06}", parent if mode == "text" else n // 100 + 1, 4096, 4096, 1, 501, ""))
        database.commit()
        database.execute("VACUUM")
        directory_bytes[mode] = path.stat().st_size
    print(json.dumps(dict(fixture="100000 directories, one materialized path per directory", **directory_bytes, reductionPercent=round(100 * (1 - directory_bytes["integer"] / directory_bytes["text"]), 2))))

    database = sqlite3.connect(base / "selection.sqlite")
    for sql in re.findall(r'try db.execute\("(CREATE (?:TABLE|INDEX)[^"\n]*)"\)', SELECTION):
        database.execute(sql)
    database.executemany("INSERT INTO selected_rows VALUES(?,1,NULL,4096,?)", ((f"/fixture/Downloads/{n:06}.zip", b"original-reviewed-metadata") for n in range(100000)))
    database.execute("INSERT INTO selected_versions VALUES('original',1,100000,409600000,0)")
    database.commit()
    changes, started = database.total_changes, time.monotonic()
    for batch in range(500):
        database.executemany("INSERT OR IGNORE INTO removed_selection VALUES('original',?)", ((f"/fixture/Downloads/{n:06}.zip",) for n in range(batch * 200, (batch + 1) * 200)))
        database.commit()
    database.execute("UPDATE selected_rows SET last=2 WHERE last IS NULL AND path IN (SELECT path FROM removed_selection WHERE token='original')")
    database.execute("INSERT INTO selected_versions VALUES('remaining',2,0,0,0)")
    database.commit()
    assert database.execute("SELECT COUNT(*) FROM selected_rows WHERE first<=1 AND (last IS NULL OR last>1)").fetchone()[0] == 100000
    print(json.dumps(dict(fixture="100000 selected, 500 removal batches, one finalization", membershipRows=database.execute("SELECT COUNT(*) FROM selected_rows").fetchone()[0], changedRows=database.total_changes - changes, seconds=round(time.monotonic() - started, 3))))
