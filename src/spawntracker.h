#pragma once

#include <QHash>
#include <QObject>
#include <QSqlDatabase>
#include <QString>
#include <cstdint>

class Item;
class SpawnShell;
class ZoneMgr;

// SpawnTracker logs spawn lifecycle + movement to a SQLite database for
// offline pattern analysis (spawn locations, respawn timing, kill vs
// natural despawn). It taps SpawnShell's existing signals — addItem,
// changeItem(position), delItem, killSpawn — so coverage grows automatically
// as more lifecycle opcodes (OP_NewSpawn / OP_DeleteSpawn) are mapped.
//
// EQ reuses spawn ids across different mobs over a session, so each sighting
// is a distinct row ("instance") keyed by an autoincrement instance_id;
// positions and the end event reference that instance, not the raw id.
//
// Schema:
//   spawns(instance_id PK, spawn_id, name, npc, level, race, class, zone,
//          first_seen, last_seen, end_event, end_time, killer_id)
//   positions(instance_id, ts, x, y, z, heading)
// end_event is 'killed' | 'despawned' | 'replaced' | NULL (still present).
class SpawnTracker : public QObject {
    Q_OBJECT
public:
    SpawnTracker(SpawnShell* shell, ZoneMgr* zoneMgr,
                 const QString& dbPath, QObject* parent = nullptr);
    ~SpawnTracker() override;

    bool isOpen() const { return m_ok; }

private slots:
    void onAddItem(const Item* item);
    void onChangeItem(const Item* item, uint32_t changeType);
    void onDelItem(const Item* item);
    void onKillSpawn(const Item* deceased, const Item* killer,
                     uint16_t killerId);

private:
    void initSchema();
    void endInstance(qint64 instanceId, const char* event,
                     qint64 whenMs, int killerId);

    SpawnShell*  m_shell   = nullptr;
    ZoneMgr*     m_zoneMgr = nullptr;
    QSqlDatabase m_db;
    bool         m_ok = false;

    struct Active { qint64 instanceId = 0; qint64 lastPosMs = 0; };
    QHash<uint32_t, Active> m_active;     // spawn_id -> current instance

    struct Kill { qint64 ms = 0; int killerId = 0; };
    QHash<uint32_t, Kill> m_recentKill;   // spawn_id -> last kill seen
};
