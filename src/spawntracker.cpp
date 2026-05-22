#include "spawntracker.h"

#include <QDateTime>
#include <QLoggingCategory>
#include <QSqlError>
#include <QSqlQuery>
#include <QVariant>

#include "spawn.h"
#include "spawnshell.h"
#include "zonemgr.h"

SpawnTracker::SpawnTracker(SpawnShell* shell, ZoneMgr* zoneMgr,
                           const QString& dbPath, QObject* parent)
    : QObject(parent)
    , m_shell(shell)
    , m_zoneMgr(zoneMgr)
{
    m_db = QSqlDatabase::addDatabase("QSQLITE", "spawntracker");
    m_db.setDatabaseName(dbPath);
    if (!m_db.open()) {
        qWarning("SpawnTracker: cannot open %s: %s",
                 qUtf8Printable(dbPath),
                 qUtf8Printable(m_db.lastError().text()));
        return;
    }
    // WAL keeps writes cheap and non-blocking enough for the main thread at
    // our write rates (positions are throttled to 1/sec/spawn).
    QSqlQuery(m_db).exec("PRAGMA journal_mode=WAL");
    QSqlQuery(m_db).exec("PRAGMA synchronous=NORMAL");
    initSchema();
    m_ok = true;

    connect(m_shell, &SpawnShell::addItem,   this, &SpawnTracker::onAddItem);
    connect(m_shell, &SpawnShell::changeItem,this, &SpawnTracker::onChangeItem);
    connect(m_shell, &SpawnShell::delItem,   this, &SpawnTracker::onDelItem);
    connect(m_shell, &SpawnShell::killSpawn, this, &SpawnTracker::onKillSpawn);

    qInfo("SpawnTracker: logging spawn lifecycle to %s", qUtf8Printable(dbPath));
}

SpawnTracker::~SpawnTracker()
{
    if (m_db.isOpen())
        m_db.close();
    QSqlDatabase::removeDatabase("spawntracker");
}

void SpawnTracker::initSchema()
{
    QSqlQuery q(m_db);
    q.exec("CREATE TABLE IF NOT EXISTS spawns ("
           "instance_id INTEGER PRIMARY KEY AUTOINCREMENT,"
           "spawn_id INTEGER, name TEXT, npc INTEGER, level INTEGER,"
           "race INTEGER, class INTEGER, zone TEXT,"
           "first_seen INTEGER, last_seen INTEGER,"
           "end_event TEXT, end_time INTEGER, killer_id INTEGER)");
    q.exec("CREATE TABLE IF NOT EXISTS positions ("
           "instance_id INTEGER, ts INTEGER,"
           "x INTEGER, y INTEGER, z INTEGER, heading INTEGER)");
    q.exec("CREATE INDEX IF NOT EXISTS idx_pos_instance ON positions(instance_id)");
    q.exec("CREATE INDEX IF NOT EXISTS idx_spawn_name ON spawns(name)");
    q.exec("CREATE INDEX IF NOT EXISTS idx_spawn_id ON spawns(spawn_id)");
}

void SpawnTracker::onAddItem(const Item* item)
{
    if (!m_ok || !item) return;
    const auto* sp = dynamic_cast<const Spawn*>(item);
    if (!sp) return;

    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    const uint32_t id = item->id();

    // EQ reuses ids: if one is still active, close the stale instance first.
    auto existing = m_active.constFind(id);
    if (existing != m_active.constEnd())
        endInstance(existing->instanceId, "replaced", now, 0);

    QSqlQuery q(m_db);
    q.prepare("INSERT INTO spawns (spawn_id,name,npc,level,race,class,zone,"
              "first_seen,last_seen) VALUES (?,?,?,?,?,?,?,?,?)");
    q.addBindValue(id);
    q.addBindValue(sp->name());
    q.addBindValue(int(sp->NPC()));
    q.addBindValue(sp->level());
    q.addBindValue(int(sp->race()));
    q.addBindValue(int(sp->classVal()));
    q.addBindValue(m_zoneMgr ? m_zoneMgr->shortZoneName() : QString());
    q.addBindValue(now);
    q.addBindValue(now);
    if (!q.exec()) return;

    m_active[id] = Active{ q.lastInsertId().toLongLong(), 0 };
}

void SpawnTracker::onChangeItem(const Item* item, uint32_t changeType)
{
    if (!m_ok || !item) return;
    if (!(changeType & tSpawnChangedPosition)) return;
    const auto* sp = dynamic_cast<const Spawn*>(item);
    if (!sp) return;

    auto it = m_active.find(item->id());
    if (it == m_active.end()) return;

    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    // Throttle: at most one position row per spawn per second. Plenty for
    // pathing analysis without exploding the table on a busy zone.
    if (now - it->lastPosMs < 1000) return;
    it->lastPosMs = now;

    QSqlQuery q(m_db);
    q.prepare("INSERT INTO positions (instance_id,ts,x,y,z,heading) "
              "VALUES (?,?,?,?,?,?)");
    q.addBindValue(it->instanceId);
    q.addBindValue(now);
    q.addBindValue(sp->x());
    q.addBindValue(sp->y());
    q.addBindValue(sp->z());
    q.addBindValue(int(sp->heading()));
    q.exec();

    QSqlQuery u(m_db);
    u.prepare("UPDATE spawns SET last_seen=? WHERE instance_id=?");
    u.addBindValue(now);
    u.addBindValue(it->instanceId);
    u.exec();
}

void SpawnTracker::onKillSpawn(const Item* deceased, const Item* /*killer*/,
                               uint16_t killerId)
{
    if (!m_ok || !deceased) return;
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    const uint32_t id = deceased->id();
    m_recentKill[id] = Kill{ now, int(killerId) };

    auto it = m_active.constFind(id);
    if (it != m_active.constEnd())
        endInstance(it->instanceId, "killed", now, int(killerId));
    // Keep it in m_active: a corpse delItem usually follows; onDelItem sees
    // the recent kill and won't overwrite the 'killed' classification.
}

void SpawnTracker::onDelItem(const Item* item)
{
    if (!m_ok || !item) return;
    const uint32_t id = item->id();
    auto it = m_active.constFind(id);
    if (it == m_active.constEnd()) return;

    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    auto k = m_recentKill.constFind(id);
    const bool killed = (k != m_recentKill.constEnd()) && (now - k->ms < 10000);
    if (killed) {
        // already finalized as 'killed' in onKillSpawn; nothing to overwrite
        m_recentKill.remove(id);
    } else {
        endInstance(it->instanceId, "despawned", now, 0);
    }
    m_active.remove(id);
}

void SpawnTracker::endInstance(qint64 instanceId, const char* event,
                               qint64 whenMs, int killerId)
{
    QSqlQuery q(m_db);
    q.prepare("UPDATE spawns SET end_event=?, end_time=?, killer_id=? "
              "WHERE instance_id=? AND end_event IS NULL");
    q.addBindValue(QString::fromLatin1(event));
    q.addBindValue(whenMs);
    q.addBindValue(killerId ? QVariant(killerId) : QVariant());
    q.addBindValue(instanceId);
    q.exec();
}
