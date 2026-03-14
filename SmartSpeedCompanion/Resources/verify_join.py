import sqlite3

db_path = "c:/Users/madhu/SmartSpeedCompanion iOS CarPlay/SmartSpeedCompanion/Resources/HPMS_2024_Data_-2111065798425599378.geodatabase"
try:
    conn = sqlite3.connect(db_path)
    cur = conn.cursor()
    # Check if OBJECTID and pkid join properly
    res = cur.execute("""
        SELECT a.OBJECTID, b.pkid, a.SpeedLimit
        FROM SpeedLimit_2024 a
        JOIN st_spindex__SpeedLimit_2024_SHAPE b ON a.OBJECTID = b.pkid
        LIMIT 5
    """).fetchall()
    print("Join samples:", res)
    conn.close()
except Exception as e:
    print(e)
